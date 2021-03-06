defmodule ConsoleWeb.Router.DeviceController do
  use ConsoleWeb, :controller
  alias Console.Repo
  import Ecto.Query
  import ConsoleWeb.AuthErrorHandler

  alias Console.Labels
  alias Console.Devices
  alias Console.Channels
  alias Console.Organizations
  alias Console.Devices.Device
  alias Console.Events
  alias Console.DcPurchases
  alias Console.DcPurchases.DcPurchase
  alias Console.Email
  alias Console.Mailer
  alias Console.LabelNotificationEvents

  @stripe_api_url "https://api.stripe.com"
  @headers [
    {"Authorization", "Bearer #{Application.get_env(:console, :stripe_secret_key)}"},
    {"Content-Type", "application/x-www-form-urlencoded"}
  ]

  def index(conn, _) do
    devices = Devices.list_devices()

    render(conn, "index.json", devices: devices)
  end

  def show(conn, %{"id" => _, "dev_eui" => dev_eui, "app_eui" => app_eui}) do
    devices = Devices.get_by_dev_eui_app_eui(dev_eui, app_eui)
    devices = Enum.map(devices, fn d ->
      if length(d.labels) > 0 do
        Map.put(d, :channels, Ecto.assoc(d.labels, :channels) |> Repo.all() |> Enum.uniq())
      else
        Map.put(d, :channels, [])
      end
    end)

    render(conn, "devices.json", devices: devices)
  end

  def show(conn, %{"id" => id}) do
    device = Devices.get_device!(id) |> Repo.preload([labels: [:channels, :function]])
    device =
      if length(device.labels) > 0 do
        channels_with_functions_and_channels =
          device.labels
          |> Enum.filter(fn l -> l.function != nil && l.function.active == true && length(l.channels) > 0 end)
          |> Enum.map(fn l ->
            Enum.map(l.channels, fn c -> Map.put(c, :function, l.function) end)
          end)
          |> List.flatten()

        channels_with_functions_no_channels =
          device.labels
          |> Enum.filter(fn l -> l.function != nil && l.function.active == true && length(l.channels) == 0 end)
          |> Enum.map(fn l ->
            %{
              function: l.function,
              id: "no_integration_id",
              name: "Console Debug Integration",
              type: "console",
              credentials: %{},
              active: false,
              organization_id: "no_organization_id",
              downlink_token: "no_downlink_token",
              payload_template: nil,
            }
          end)
          |> List.flatten()

        channels_without_functions =
          device.labels
          |> Enum.filter(fn l -> l.function == nil || l.function.active == false end)
          |> Enum.map(fn l -> l.channels end)
          |> List.flatten()
          |> Enum.uniq()
          |> Enum.map(fn c -> Map.put(c, :function, nil) end)

        adr_allowed = device.labels |> Enum.map(fn l -> l.adr_allowed end) |> Enum.find(fn s -> s == true end)
        device =
          case adr_allowed do
            true -> Map.put(device, :adr_allowed, true)
            _ -> device
          end

        multi_buy_value = device.labels |> Enum.map(fn l -> l.multi_buy end) |> Enum.max
        case multi_buy_value do
          0 ->
            Map.put(device, :channels, channels_with_functions_and_channels ++ channels_with_functions_no_channels ++ channels_without_functions)
          10 ->
            Map.put(device, :channels, channels_with_functions_and_channels ++ channels_with_functions_no_channels ++ channels_without_functions)
            |> Map.put(:multi_buy, 9999) #9999 is the value for router to indicate all available packets
          _ ->
            Map.put(device, :channels, channels_with_functions_and_channels ++ channels_with_functions_no_channels ++ channels_without_functions)
            |> Map.put(:multi_buy, multi_buy_value)
        end
      else
        Map.put(device, :channels, [])
      end

    render(conn, "show.json", device: device)
  end

  def add_device_event(conn, %{"device_id" => device_id} = event) do
    # for passing to debug panel, not stored in db
    channels_with_debug =
      event["channels"]
      |> Enum.map(fn c ->
        case c["debug"] do
          nil -> c
          value -> Map.put(c, "debug", Jason.encode!(value))
        end
      end)
      |> Enum.map(fn c ->
        c |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
      end)

    # for storing event in db, no debug info attached
    channels_without_debug =
      event["channels"]
      |> Enum.map(fn c ->
        Map.drop(c, ["debug"])
      end)

    payload = event["payload"]

    event = event
      |> Map.put("channels", channels_without_debug)
      |> Map.put("reported_at_epoch", event["reported_at"])
    event =
      cond do
        is_integer(event["port"]) -> event
        event["port"] != nil and Integer.parse(event["port"]) != :error -> event
        true -> Map.put(event, "port", nil)
      end
    event =
      case event["dc"]["used"] do
        nil -> Map.put(event, "dc_used", 0)
        dc -> Map.put(event, "dc_used", dc)
      end

    # store info before updating device
    event_device = Devices.get_device(device_id) |> Repo.preload([:labels])

    case event_device do
      nil ->
        conn
        |> send_resp(404, "")
      %Device{} = device ->
        organization = Organizations.get_organization!(device.organization_id)
        prev_dc_balance = organization.dc_balance

        result =
          Ecto.Multi.new()
          |> Ecto.Multi.run(:event, fn _repo, _ ->
            Events.create_event(Map.put(event, "organization_id", organization.id))
          end)
          |> Ecto.Multi.run(:device, fn _repo, %{ event: event } ->
            Devices.update_device(device, %{
              "last_connected" => event.reported_at_naive,
              "frame_up" => event.frame_up,
              "frame_down" => event.frame_down,
              "total_packets" => device.total_packets + 1,
              "dc_usage" => device.dc_usage + event.dc_used,
            }, "router")
          end)
          |> Ecto.Multi.run(:organization, fn _repo, %{ device: device, event: created_event } ->
            cond do
              organization.dc_balance_nonce == event["dc"]["nonce"] ->
                Organizations.update_organization(organization, %{ "dc_balance" => event["dc"]["balance"] })
              organization.dc_balance_nonce - 1 == event["dc"]["nonce"] ->
                {:ok, updated_org} = Organizations.update_organization(organization, %{ "dc_balance" => organization.dc_balance - created_event.dc_used })
                ConsoleWeb.DataCreditController.broadcast_router_refill_dc_balance(updated_org)

                {:ok, updated_org}
              true ->
                {:error, "DC balance nonce inconsistent between router and console"}
            end
          end)
          |> Repo.transaction()

        with {:ok, %{ event: event, device: device, organization: organization }} <- result do
          publish_created_event(event, payload, device, channels_with_debug)
          check_org_dc_balance(organization, prev_dc_balance)

          if event_device.last_connected == nil do
            { _, time } = Timex.format(Timex.now, "%H:%M:%S UTC", :strftime)
            details = %{
              device_name: event_device.name,
              time: time,
              hotspots: Enum.map(event.hotspots, fn h -> %{ name: h.name, rssi: h.rssi, snr: h.snr, spreading: h.spreading, frequency: h.frequency } end)
            }
            device_labels = Enum.map(event_device.labels, fn l -> l.id end)
            LabelNotificationEvents.notify_label_event(device_labels, "device_join_otaa_first_time", details)
          end

          case event.category do
            "up" ->
              Enum.each(event.channels, fn channel ->
                if channel.id != "no_channel" and channel.id != "no_integration_id" do
                  event_channel = Channels.get_channel(channel.id) |> Repo.preload([:labels])
                  labels = Enum.map(event_channel.labels, fn l -> l.id end)

                  if event_channel.time_first_uplink == nil do
                    Channels.update_channel(event_channel, organization, %{ time_first_uplink: event.reported_at_naive })
                    { _, time } = Timex.format(event.reported_at_naive, "%H:%M:%S UTC", :strftime)
                    details = %{ time: time, channel_name: event_channel.name, channel_id: event_channel.id }
                    LabelNotificationEvents.notify_label_event(labels, "integration_receives_first_event", details)
                  end

                  if channel.status != "success" do
                    { _, time } = Timex.format(event.reported_at_naive, "%H:%M:%S UTC", :strftime)
                    details = %{
                      channel_name: event_channel.name,
                      channel_id: event_channel.id,
                      time: time
                    }
                    limit = %{ integration_id: event_channel.id, time_buffer: Timex.shift(Timex.now, hours: -1) }
                    LabelNotificationEvents.notify_label_event(labels, "integration_stops_working", details, limit)
                  end
                end
              end)
            "down" ->
              if List.first(event.hotspots).status != "success" do
                details = %{ device_id: event_device.id, device_name: event_device.name }
                device_labels = Enum.map(event_device.labels, fn l -> l.id end)
                limit = %{ device_id: event_device.id, time_buffer: Timex.shift(Timex.now, hours: -1) }
                LabelNotificationEvents.notify_label_event(device_labels, "downlink_unsuccessful", details, limit)
              end
            _ -> nil
          end

          conn
          |> send_resp(200, "")
        end
    end
  end

  defp publish_created_event(event, payload, device, channels_with_debug) do
    event =
      case payload do
        nil ->
          Map.merge(event, %{
            device_name: device.name,
            hotspots: Jason.encode!(event.hotspots),
            channels: Jason.encode!(event.channels)
          })
        _ ->
          Map.merge(event, %{
            device_name: device.name,
            payload: payload,
            hotspots: Jason.encode!(event.hotspots),
            channels: Jason.encode!(channels_with_debug)
          })
      end

    event_to_publish =
      event
      |> Map.from_struct()
      |> Map.delete(:__meta__)
      |> Map.delete(:__struct__)
      |> Map.delete(:device)
      |> Map.delete(:organization)

    ConsoleWeb.Endpoint.broadcast("graphql:events_dashboard", "graphql:events_dashboard:#{device.id}:new_event", event_to_publish)
    ConsoleWeb.Endpoint.broadcast("graphql:device_show_debug", "graphql:device_show_debug:#{device.id}:get_event", event_to_publish)

    label_ids = Labels.get_labels_of_device(device) |> Enum.map(fn dl -> dl.label_id end)
    Enum.each(label_ids, fn id ->
      ConsoleWeb.Endpoint.broadcast("graphql:label_show_debug", "graphql:label_show_debug:#{id}:get_event", event_to_publish)
    end)
  end

  defp check_org_dc_balance(organization, prev_dc_balance) do
    if organization.automatic_charge_amount == nil do
      cond do
        prev_dc_balance > 500_000 and organization.dc_balance <= 500_000 ->
          # DC Balance has dipped below 500,000. Send a notice.
          Organizations.get_administrators(organization)
          |> Enum.each(fn administrator ->
            Email.dc_balance_notification_email(organization, administrator.email, organization.dc_balance)
            |> Mailer.deliver_later()
          end)
        prev_dc_balance > 0 and organization.dc_balance <= 0 ->
          # DC Balance has gone to zero. Send a notice.
          Organizations.get_administrators(organization)
          |> Enum.each(fn administrator ->
            Email.dc_balance_notification_email(organization, administrator.email, 0) |> Mailer.deliver_later()
          end)
        true -> nil
      end
    end

    if organization.automatic_charge_amount != nil
      and organization.automatic_payment_method != nil
      and organization.dc_balance < 500000
      and not organization.pending_automatic_purchase do

        {:ok, updated_org_pending_result} =
          Repo.transaction(fn ->
            organization = Organizations.get_organization!(organization.id)
            if organization.pending_automatic_purchase do
              nil
            else
              Organizations.update_organization!(organization, %{ "pending_automatic_purchase" => true })
            end
          end)

        case updated_org_pending_result do
          nil -> nil
          organization ->
            request_body = URI.encode_query(%{
              "customer" => organization.stripe_customer_id,
              "amount" => organization.automatic_charge_amount,
              "currency" => "usd",
              "payment_method" => organization.automatic_payment_method,
              "off_session" => "true",
              "confirm" => "true",
            })

            with {:ok, stripe_response} <- HTTPoison.post("#{@stripe_api_url}/v1/payment_intents", request_body, @headers) do
              with 200 <- stripe_response.status_code do
                payment_intent = Poison.decode!(stripe_response.body)

                with "succeeded" <- payment_intent["status"],
                  {:ok, stripe_response} <- HTTPoison.get("#{@stripe_api_url}/v1/payment_methods/#{payment_intent["payment_method"]}", @headers),
                  200 <- stripe_response.status_code do
                    card = Poison.decode!(stripe_response.body)

                    attrs = %{
                      "dc_purchased" => payment_intent["amount"] * 1000,
                      "cost" => payment_intent["amount"],
                      "card_type" => card["card"]["brand"],
                      "last_4" => card["card"]["last4"],
                      "user_id" => "Recurring Charge",
                      "organization_id" => organization.id,
                      "payment_id" => payment_intent["id"],
                    }

                    with {:ok, %DcPurchase{} = dc_purchase } <- DcPurchases.create_dc_purchase_update_org(attrs, organization) do
                      organization = Organizations.get_organization!(organization.id)
                      Organizations.get_administrators(organization)
                      |> Enum.each(fn administrator ->
                        Email.dc_top_up_notification_email(organization, dc_purchase, administrator.email)
                        |> Mailer.deliver_later()
                      end)
                      ConsoleWeb.Endpoint.broadcast("graphql:dc_purchases_table", "graphql:dc_purchases_table:#{organization.id}:update_dc_table", %{})
                      ConsoleWeb.Endpoint.broadcast("graphql:dc_index", "graphql:dc_index:#{organization.id}:update_dc", %{})
                      ConsoleWeb.DataCreditController.broadcast_router_refill_dc_balance(organization)
                    end
                end
              end
            end
        end
    end
  end
end
