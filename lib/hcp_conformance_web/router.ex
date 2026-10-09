defmodule HcpConformanceWeb.Router do
  use HcpConformanceWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug HcpConformanceWeb.BasicAuth
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {HcpConformanceWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug HcpConformanceWeb.BasicAuth
  end

  # Open even behind basic auth, for load balancers.
  scope "/", HcpConformanceWeb do
    get "/health", ApiController, :health
  end

  scope "/", HcpConformanceWeb do
    pipe_through :browser

    get "/", SessionController, :new
    post "/session", SessionController, :create
    delete "/session", SessionController, :delete
    live "/run", RunLive
    get "/checks", PageController, :checks
    get "/hook", PageController, :hook
  end

  scope "/api", HcpConformanceWeb do
    pipe_through :api

    post "/runs", ApiController, :create
    get "/checks", ApiController, :checks
  end
end
