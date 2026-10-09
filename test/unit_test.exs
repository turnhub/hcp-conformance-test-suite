defmodule HcpConformance.UnitTest do
  use ExUnit.Case, async: true

  alias HcpConformance.Assert
  alias HcpConformance.Checks.Audit
  alias HcpConformance.Checks.Grants
  alias HcpConformance.Config
  alias HcpConformance.Envelope
  alias HcpConformance.HTTP.Response
  alias HcpConformance.TargetGuard
  alias HcpConformance.Transcript

  @entry %{
    "@context" => Envelope.context(),
    "id" => "urn:uuid:7f3a1b2c-4d5e-6f7a-8b9c-0d1e2f3a4b5c",
    "type" => ["HCPEntry"],
    "credentialType" => "NLPreference",
    "claim" => %{
      "issuer" => %{"id" => "did:web:assistant.example.com", "type" => "HCPSource"},
      "issuanceDate" => "2026-06-15T10:30:00Z",
      "expirationDate" => nil,
      "subject" => %{
        "id" => "did:hcp:user:pseudonym-a3f9",
        "relationship" => nil,
        "preference" => "I require high arch support."
      }
    },
    "record" => %{
      "category" => "health_context",
      "dimension" => "footwear_support",
      "declarationType" => "user-declared",
      "confidence" => nil,
      "status" => "active",
      "version" => 1,
      "previousVersion" => nil,
      "provenance" => %{
        "source" => "conversation-id:abc123",
        "capturedAt" => "2026-06-15T10:30:00Z",
        "capturedBy" => "agent:claude-assistant-v1",
        "userVerified" => true
      }
    }
  }

  describe "Envelope.validate/3" do
    test "accepts the specification's own Tier 1 example (§2.3)" do
      assert Envelope.validate(@entry, "grouped") == []
    end

    test "accepts the same entry in the flat form" do
      flat =
        @entry
        |> Map.drop(["claim", "record"])
        |> Map.merge(@entry["claim"])
        |> Map.merge(@entry["record"])

      assert Envelope.validate(flat, "flat") == []
    end

    test "names each broken data-model rule" do
      broken =
        @entry
        |> put_in(["record", "declarationType"], "model-inferred")
        |> put_in(["record", "version"], 3)
        |> put_in(["record", "previousVersion"], 1)
        |> Map.put("@context", ["https://hcp.me/contexts/v1"])

      assert [context, confidence, previous] = Envelope.validate(broken, "grouped")
      assert context =~ "@context"
      assert confidence =~ "confidence"
      assert previous =~ "previousVersion"
    end

    test "accepts redacted provenance only when asked to" do
      redacted =
        update_in(@entry, ["record", "provenance"], &Map.drop(&1, ["source", "capturedBy"]))

      assert ["record.provenance.source must be a string"] =
               Envelope.validate(redacted, "grouped")

      assert Envelope.validate(redacted, "grouped", redacted: true) == []
    end

    test "reads and names fields in either form" do
      assert Envelope.get(@entry, "grouped", ["record", "status"]) == "active"
      assert Envelope.get(%{"status" => "active"}, "flat", ["record", "status"]) == "active"
      assert Envelope.path("flat", ["record", "provenance", "source"]) == "provenance.source"

      assert Envelope.path("grouped", ["record", "provenance", "source"]) ==
               "record.provenance.source"
    end
  end

  describe "messages quoting a response body" do
    test "quote text as it is, cut to a length" do
      assert Transcript.excerpt("héllo wörld", 5) == "héllo"
      assert Assert.body_hint(%Response{body: "not found"}) == " (body: not found)"
    end

    test "describe a body that is not UTF-8 instead of quoting it, so a report can always print" do
      gzip = :zlib.gzip("{}")

      assert Transcript.excerpt(gzip, 300) == "[binary body, #{byte_size(gzip)} bytes]"

      assert Assert.body_hint(%Response{body: gzip}) ==
               " (body: [binary body, #{byte_size(gzip)} bytes])"
    end
  end

  describe "TargetGuard" do
    test "classifies private and public addresses" do
      for address <- [
            {127, 0, 0, 1},
            {10, 1, 2, 3},
            {172, 16, 0, 1},
            {192, 168, 1, 1},
            {169, 254, 169, 254},
            {100, 64, 0, 1},
            {0, 0, 0, 0, 0, 0, 0, 1},
            {0xFD00, 0, 0, 0, 0, 0, 0, 1},
            {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}
          ] do
        assert TargetGuard.private?(address), inspect(address)
      end

      for address <- [
            {8, 8, 8, 8},
            {1, 1, 1, 1},
            {0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111},
            {0, 0, 0, 0, 0, 0xFFFF, 0x0808, 0x0808}
          ] do
        refute TargetGuard.private?(address), inspect(address)
      end
    end

    test "draws each IPv4 block's edges exactly" do
      private = [
        {0, 255, 255, 255},
        {100, 64, 0, 0},
        {100, 127, 255, 255},
        {172, 31, 255, 255},
        {198, 18, 0, 0},
        {198, 19, 255, 255},
        {224, 0, 0, 0},
        {255, 255, 255, 255}
      ]

      public = [
        {1, 0, 0, 0},
        {9, 255, 255, 255},
        {11, 0, 0, 0},
        {100, 63, 255, 255},
        {100, 128, 0, 0},
        {126, 255, 255, 255},
        {128, 0, 0, 0},
        {169, 253, 255, 255},
        {169, 255, 0, 0},
        {172, 15, 255, 255},
        {172, 32, 0, 0},
        {192, 167, 255, 255},
        {192, 169, 0, 0},
        {198, 17, 255, 255},
        {198, 20, 0, 0},
        {223, 255, 255, 255}
      ]

      assert Enum.reject(private, &TargetGuard.private?/1) == []
      assert Enum.filter(public, &TargetGuard.private?/1) == []
    end

    test "refuses private targets unless allowed" do
      assert {:error, message} = TargetGuard.check("http://127.0.0.1:4000/v1", false)
      assert message =~ "non-public"
      assert TargetGuard.check("http://127.0.0.1:4000/v1", true) == :ok
      assert {:error, _message} = TargetGuard.check("file:///etc/passwd", false)
    end
  end

  test "Audit.readable?/1 sees through sequence numbers and encodings" do
    for cursor <- [
          "42",
          Base.encode64("42"),
          Base.url_encode64(~s({"offset":40}), padding: false),
          "offset=10"
        ] do
      assert Audit.readable?(cursor), cursor
    end

    refute Audit.readable?(Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false))
  end

  test "Grants.grant_violations/1 enforces the §4.1.5 object" do
    grant = %{
      "grantId" => "urn:uuid:1",
      "client" => %{"id" => "c", "name" => "Recipe app"},
      "scopes" => ["hcp:health_context:read"],
      "grantType" => "temporary",
      "issuedAt" => "2026-10-09T10:00:00Z",
      "expiresAt" => "2026-10-09T11:00:00Z",
      "status" => "active"
    }

    assert Grants.grant_violations(grant) == []
    assert [wildcard] = Grants.grant_violations(%{grant | "scopes" => ["hcp:*:read"]})
    assert wildcard =~ "wildcards"
    assert [expiry] = Grants.grant_violations(%{grant | "expiresAt" => nil})
    assert expiry =~ "non-null expiresAt"
  end

  describe "Config.new/1" do
    test "picks the mode from what is supplied" do
      assert {:ok, config} =
               Config.new(%{
                 "target" => "https://vault.example.com/",
                 "hook_url" => "https://vault.example.com/hook",
                 "hook_secret" => "s"
               })

      assert config.target == "https://vault.example.com"
      assert Config.mode(config) == :hook
      assert {:ok, config} = Config.new(%{target: "https://vault.example.com", person_token: "t"})
      assert Config.mode(config) == :static

      assert {:ok, config} =
               Config.new(%{target: "https://vault.example.com", person_token: "  "})

      assert Config.mode(config) == :anonymous
    end

    test "derives the target from a discovery URL" do
      assert {:ok, %{target: "https://vault.example.com/apps/1"}} =
               Config.new(%{
                 discovery_url: "https://vault.example.com/apps/1/.well-known/hcp-configuration"
               })
    end

    test "rejects what cannot run" do
      assert {:error, _message} = Config.new(%{})
      assert {:error, _message} = Config.new(%{target: "ftp://vault.example.com"})

      assert {:error, _message} =
               Config.new(%{
                 target: "https://vault.example.com",
                 hook_url: "https://vault.example.com/hook"
               })
    end

    test "public/1 carries no credentials" do
      {:ok, config} =
        Config.new(%{
          target: "https://v.example.com",
          hook_url: "https://v.example.com/h",
          hook_secret: "secret",
          person_token: "token"
        })

      refute config |> Config.public() |> inspect() =~ "secret"
      refute config |> Config.public() |> inspect() =~ "token\""
    end
  end

  test "docs/CHECKS.md matches the catalogue (regenerate with mix hcp.checks > docs/CHECKS.md)" do
    assert File.read!("docs/CHECKS.md") == HcpConformance.CLI.catalogue()
  end
end
