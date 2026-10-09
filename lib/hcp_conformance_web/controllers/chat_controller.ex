defmodule HcpConformanceWeb.ChatController do
  @moduledoc """
  Keeps the visitor's OpenAI key for the chat page in their session cookie, which
  the endpoint encrypts. The server stores nothing, as with the target's
  credentials.
  """

  use HcpConformanceWeb, :controller

  @default_model "gpt-5.4-mini"

  @doc "The model used when the visitor names none."
  @spec default_model() :: String.t()
  def default_model, do: @default_model

  def create(conn, %{"openai" => params}) do
    case {trimmed(params["key"]), trimmed(params["model"])} do
      {"", _model} ->
        conn |> put_flash(:error, "Enter an OpenAI API key.") |> redirect(to: ~p"/chat")

      {key, model} ->
        conn
        |> put_session(:openai, %{
          "key" => key,
          "model" => if(model == "", do: @default_model, else: model)
        })
        |> redirect(to: ~p"/chat")
    end
  end

  def create(conn, _params), do: create(conn, %{"openai" => %{}})

  def delete(conn, _params) do
    conn
    |> delete_session(:openai)
    |> put_flash(:info, "The OpenAI key is gone from your session.")
    |> redirect(to: ~p"/chat")
  end

  defp trimmed(value) when is_binary(value), do: String.trim(value)
  defp trimmed(_value), do: ""
end
