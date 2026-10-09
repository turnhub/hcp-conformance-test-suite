defmodule HcpConformance.Reference.ServerTest do
  # Pins the reference's validation one rule at a time; the conformance and
  # fault-detection tests cover its behaviour as a whole.
  use ExUnit.Case, async: true

  alias HcpConformance.Reference.Server
  alias HcpConformance.ReferenceTarget

  @entry %{
    "claim" => %{
      "issuer" => %{"id" => "did:web:assistant.example.com"},
      "subject" => %{"id" => "did:hcp:user:a", "preference" => "Window seats."}
    },
    "record" => %{
      "category" => "general_preferences",
      "declarationType" => "user-declared",
      "confidence" => nil,
      "provenance" => %{"source" => "conversation"}
    }
  }

  describe "validate_entry/1" do
    test "accepts a grouped Tier 1 entry, inferred ones with a confidence" do
      assert Server.validate_entry(@entry) == :ok

      assert Server.validate_entry(put_in(@entry, ["record", "category"], "hcp-custom:diet")) ==
               :ok

      inferred =
        @entry
        |> put_in(["record", "declarationType"], "model-inferred")
        |> put_in(["record", "confidence"], "low")

      assert Server.validate_entry(inferred) == :ok
    end

    test "names the first rule an entry breaks" do
      for {entry, message} <- [
            {[], "the body must be an HCPEntry object"},
            {Map.put(@entry, "credentialType", "VerifiablePreference"),
             "Tier 2 entries are not supported"},
            {Map.delete(@entry, "claim"), "claim and record are required (grouped form)"},
            {put_in(@entry, ["claim", "issuer"], "did:web:a"), "claim.issuer.id is required"},
            {put_in(@entry, ["claim", "subject", "id"], 7), "claim.subject.id is required"},
            {put_in(@entry, ["claim", "subject", "preference"], nil),
             "claim.subject.preference is required"},
            {put_in(@entry, ["record", "category"], "shoes"),
             "record.category must be a registered category"},
            {put_in(@entry, ["record", "dimension"], 3), "record.dimension must be a string"},
            {put_in(@entry, ["record", "declarationType"], "guessed"),
             "record.declarationType is required"},
            {put_in(@entry, ["record", "declarationType"], "model-inferred"),
             "model-inferred entries require confidence"},
            {put_in(@entry, ["record", "confidence"], "high"),
             "confidence must be null unless model-inferred"},
            {put_in(@entry, ["record", "provenance"], %{}),
             "record.provenance.source is required"}
          ] do
        assert Server.validate_entry(entry) == {:error, message}
      end
    end
  end

  describe "the conformance hook's grant request" do
    setup do
      target = ReferenceTarget.start!()
      auth = [auth: {:bearer, target.hook_secret}, retry: false]

      %{"subjectId" => subject} =
        Req.post!(target.hook_url <> "/subjects", [json: %{}] ++ auth).body

      grant = fn body ->
        Req.post!("#{target.hook_url}/subjects/#{subject}/grants", [json: body] ++ auth)
      end

      %{grant: grant}
    end

    @grant %{
      "clientId" => "c",
      "clientName" => "Client",
      "actorType" => "agent",
      "scopes" => ["hcp:general_preferences:read"],
      "grantType" => "temporary",
      "expiresInSeconds" => 60
    }

    test "issues a valid grant", %{grant: grant} do
      assert %{status: 201, body: %{"token" => "ref-grant-" <> _}} = grant.(@grant)

      assert %{status: 201, body: %{"expiresAt" => nil}} =
               grant.(%{@grant | "grantType" => "persistent"})
    end

    test "answers 422 naming the first rule a request breaks", %{grant: grant} do
      for {body, message} <- [
            {%{@grant | "scopes" => ["hcp:*:read"]},
             "scopes must be hcp:{category}:{read|write} strings without wildcards"},
            {%{@grant | "scopes" => []},
             "scopes must be hcp:{category}:{read|write} strings without wildcards"},
            {%{@grant | "grantType" => "forever"}, "grantType must be temporary or persistent"},
            {%{@grant | "expiresInSeconds" => 86_401},
             "a temporary grant expires within 24 hours"},
            {Map.put(@grant, "restrictions", [%{"scope" => "hcp:goals_and_constraints:read"}]),
             "every restriction must reference a scope the grant holds"},
            {Map.delete(@grant, "clientName"), "clientId and clientName are required"}
          ] do
        assert %{status: 422, body: %{"detail" => ^message}} = grant.(body)
      end
    end
  end
end
