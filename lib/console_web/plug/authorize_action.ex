defmodule ConsoleWeb.Plug.AuthorizeAction do
  import Plug.Conn, only: [send_resp: 3, halt: 1]
  import ConsoleWeb.Abilities

  def init(default), do: default

  def call(conn, _default) do
    current_membership = conn.assigns.current_membership
    action = conn.private.phoenix_action
    controller = conn.private.phoenix_controller

    if can?(current_membership, action, controller) do
      conn
    else
      conn
      |> send_resp(
        :forbidden,
        Poison.encode!(%{
          type: "forbidden_action",
          errors: ["You don't have access to do this"]
        })
      )
      |> halt()
    end
  end
end
