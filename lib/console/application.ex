defmodule Console.Application do
  use Application

  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, _args) do
    import Supervisor.Spec

    # Define workers and child supervisors to be supervised
    children = [
      {Phoenix.PubSub, name: MyApp.PubSub},
      # Start the Ecto repository
      supervisor(Console.Repo, []),
      # Start the endpoint when the application starts
      supervisor(ConsoleWeb.Endpoint, []),
      supervisor(Absinthe.Subscription, [ConsoleWeb.Endpoint]),
      worker(ConsoleWeb.Monitor, [%{}]),
      # Start your own worker by calling: Console.Worker.start_link(arg1, arg2, arg3)
      # worker(Console.Worker, [arg1, arg2, arg3]),
      {Task.Supervisor, name: ConsoleWeb.TaskSupervisor},
      Console.Scheduler
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Console.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    ConsoleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
