defmodule HcpConformanceWeb.ChatController do
  @moduledoc """
  Keeps the visitor's API keys for the chat page's assistants in their session
  cookie, which the endpoint encrypts. The server stores nothing, as with the
  target's credentials.
  """

  use HcpConformanceWeb, :controller

  alias HcpConformance.Assistants

  def create(conn, %{"key" => %{"assistant" => id} = params}) do
    case {Assistants.get(id), trimmed(params["key"])} do
      {nil, _key} ->
        conn |> put_flash(:error, "No such assistant.") |> redirect(to: ~p"/chat")

      {_assistant, ""} ->
        conn |> put_flash(:error, "Enter an API key.") |> redirect(to: ~p"/chat")

      {assistant, key} ->
        model = with "" <- trimmed(params["model"]), do: assistant.default_model

        keys =
          Map.put(get_session(conn, :assistants) || %{}, id, %{"key" => key, "model" => model})

        conn |> put_session(:assistants, keys) |> redirect(to: ~p"/chat")
    end
  end

  def create(conn, _params),
    do: conn |> put_flash(:error, "Enter an API key.") |> redirect(to: ~p"/chat")

  def delete(conn, %{"assistant" => id}) do
    conn
    |> put_session(:assistants, Map.delete(get_session(conn, :assistants) || %{}, id))
    |> put_flash(:info, "The key is gone from your session.")
    |> redirect(to: ~p"/chat")
  end

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""
end
