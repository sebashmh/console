# Console

Code that powers the official [Helium Console](https://console.helium.com/).

## Development and Contribution

Any and all contributions from the community are encouraged.

- Guidelines for how to contribute to this repository [are here](https://github.com/helium/console/blob/master/CONTRIBUTING.md).
- Discussion about the development and usage of the Helium Console takes place in the [official Helium Discord Server](https://discord.gg/helium), specifically in the `#console` channel. Join us!
- For a list of issues and prioritization, please go to our [Project page](https://github.com/orgs/helium/projects/15).

## Running Console Development Environment

  * Install homebrew (https://brew.sh/)
  * Install postgres (postgres.app on mac)
  * Install yarn (`brew install yarn`)
  * Install libsodium (`brew install libsodium`)
  * Install erlang (https://thinkingelixir.com/install-elixir-using-asdf/) (asdf install erlang 21.1, asdf local erlang 21.1)
  * Install elixir (https://thinkingelixir.com/install-elixir-using-asdf/) (asdf install elixir 1.9.0, asdf local elixir 1.9.0)

To start your Phoenix server:

  * Install dependencies with `mix deps.get`
  * Create and migrate your database with `mix ecto.setup`
  * Install Node.js dependencies with `cd assets && yarn`
  * Start Phoenix with `mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Running Console+Router with Docker

  * Clone the repo and `cd console`
  * Update host at the top of `/config/releases.exs`
  * Sign up with Auth0 (https://auth0.com/)
  * Create .env and .env-router files in root folder
  * Populate .env file with the following

  ```
  SECRET_KEY_BASE=[Random 64 char secret key]
  CLOAK_SECRET_KEY=[Run in iex: 32 |> :crypto.strong_rand_bytes() |> Base.encode64()]
  GUARDIAN_SECRET_KEY=[Random 64 char secret key]
  ROUTER_SECRETS=[Unix Timestamp:Random 64 char secret key]
  OUI=3
  SELF_HOSTED=true
  ENV_DOMAIN=[Your host domain]
  AUTH_0_CLIENT_ID=[Client ID under Auth0 app settings]
  AUTH_0_DOMAIN=[Domain under Auth0 app settings]
  AUTH0_BASE_URL=[https:// + Auth0 Domain]
  MAILGUN_API_KEY=[Your Mailgun api key (optional)]
  SITE_DOMAIN_MAILGUN=[Your Mailgun host domain (optional)]
  DATABASE_DB=console
  DATABASE_HOST=postgres
  ```
  * Populate .env-router file with the following
  ```
  ROUTER_SEED_NODES=/ip4/34.222.64.221/tcp/2154,/ip4/34.208.255.251/tcp/2154
  ROUTER_CONSOLE_ENDPOINT=http://helium_console:4000
  ROUTER_CONSOLE_WS_ENDPOINT=ws://helium_console:4000/socket/router/websocket
  ROUTER_CONSOLE_SECRET=[Random 64 char secret key from above]
  ROUTER_OUI=3
  ROUTER_DEFAULT_DEVADDR=AAQASA==
  ROUTER_SC_OPEN_DC_AMOUNT=100000
  ROUTER_SC_EXPIRATION_INTERVAL=45
  ```

  * Build with `docker-compose build`
  * Run with `docker-compose up`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Questions

If you run into any issues or you have any questions about how to get started contributing, feel free to reach out on the `#console` channel in [the official Helium Community Discord server](http://discord.gg/helium)!
