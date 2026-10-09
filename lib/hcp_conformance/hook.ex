defmodule HcpConformance.Hook do
  @moduledoc """
  Client for the conformance hook (docs/HOOK.md).

  HCP §5.4 says a first-party implementation still needs "a means for the suite to
  obtain a credential and trigger grant creation", and that the suite
  specification defines a test hook for it. That suite specification is not
  published, so this suite defines the hook: three HTTP calls, authenticated with
  a shared secret, that create a test subject, issue a grant as that subject's
  own act, and dispose of the subject.
  """

  alias HcpConformance.HTTP

  @doc "Creates a fresh subject. Returns `%{subject_id, subject_did, person_token}`."
  @spec create_subject(pid(), boolean(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def create_subject(transcript, allow_private, hook_url, secret) do
    response =
      HTTP.request(transcript, allow_private, :post, hook_url <> "/subjects",
        token: secret,
        json: %{"purpose" => "HCP conformance run"},
        kind: :hook,
        secret_fields: ["personToken"]
      )

    case response do
      %{status: status, json: %{"subjectId" => id, "personToken" => token} = body}
      when status in [200, 201] ->
        {:ok, %{subject_id: id, subject_did: body["subjectDid"], person_token: token}}

      %{status: status, body: body} ->
        {:error, "POST /subjects answered #{status}: #{String.slice(body, 0, 300)}"}
    end
  end

  @doc """
  Issues a grant as the subject's own act. `attrs` follow docs/HOOK.md
  (`scopes`, `grantType`, `expiresInSeconds`, `restrictions`, `clientId`,
  `clientName`, `actorType`). Returns `%{grant_id, token, client_id}`.
  """
  @spec issue_grant(pid(), boolean(), String.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, String.t()}
  def issue_grant(transcript, allow_private, hook_url, secret, subject_id, attrs) do
    url = hook_url <> "/subjects/" <> URI.encode(subject_id, &URI.char_unreserved?/1) <> "/grants"

    case HTTP.request(transcript, allow_private, :post, url,
           secret_fields: ["token"],
           token: secret,
           json: attrs,
           kind: :hook
         ) do
      %{status: status, json: %{"grantId" => grant_id, "token" => token} = body}
      when status in [200, 201] ->
        {:ok,
         %{
           grant_id: grant_id,
           token: token,
           client_id: attrs["clientId"],
           expires_at: body["expiresAt"]
         }}

      %{status: status, body: body} ->
        {:error, "POST /subjects/{id}/grants answered #{status}: #{String.slice(body, 0, 300)}"}
    end
  end

  @doc "Asks the implementation to dispose of a test subject. Best effort."
  @spec delete_subject(pid(), boolean(), String.t(), String.t(), String.t()) :: :ok
  def delete_subject(transcript, allow_private, hook_url, secret, subject_id) do
    url = hook_url <> "/subjects/" <> URI.encode(subject_id, &URI.char_unreserved?/1)
    HTTP.request(transcript, allow_private, :delete, url, token: secret, kind: :hook)
    :ok
  rescue
    HTTP.TransportError -> :ok
  end
end
