defmodule HcpConformance.V2.VersionsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias HcpConformance.{Catalog, CLI, Config, ReferenceTarget, Spec}

  describe "Spec" do
    test "reads a version however it is written, and nothing else" do
      assert Spec.parse("2.0") == {:ok, "2.0"}
      assert Spec.parse("v2") == {:ok, "2.0"}
      assert Spec.parse("2.0-draft-3") == {:ok, "2.0"}
      assert Spec.parse("1") == {:ok, "1.0"}
      assert Spec.parse(nil) == {:ok, nil}
      assert Spec.parse("auto") == {:ok, nil}
      assert Spec.parse("3.0") == :error
      assert Spec.parse(2) == :error
    end

    test "detects the version a discovery document speaks, falling back to v1" do
      assert Spec.detect(%{"hcp_version" => "2.0"}) == "2.0"
      assert Spec.detect(%{"hcp_version" => "1.0"}) == "1.0"
      assert Spec.detect(%{}) == "1.0"
      assert Spec.detect(nil) == "1.0"
    end

    test "names the draft each version's checks follow" do
      assert Enum.map(Spec.versions(), &Spec.draft/1) == ["1.0-draft-4", "2.0-draft-3"]
      assert Spec.label("2.0") == "HCP v2 (2.0-draft-3)"
    end
  end

  describe "Config" do
    test "normalizes spec_version and leaves it unset for detection" do
      assert {:ok, %{spec_version: "2.0"}} =
               Config.new(%{target: "https://v.example.com", spec_version: "v2"})

      assert {:ok, %{spec_version: nil}} = Config.new(%{target: "https://v.example.com"})

      assert {:ok, %{spec_version: nil}} =
               Config.new(%{target: "https://v.example.com", spec_version: "auto"})
    end

    test "refuses a version the suite has no checks for" do
      assert {:error, message} =
               Config.new(%{target: "https://v.example.com", spec_version: "3.0"})

      assert message =~ "spec_version"
    end
  end

  describe "Catalog" do
    test "v1 stays the default, and its checks are untouched by v2's" do
      assert Catalog.all() == Catalog.all("1.0")
      assert length(Catalog.all("1.0")) == 94
      assert Catalog.groups() == Catalog.groups("1.0")
    end

    test "every v2 check has a unique id, a group, and a section of the v2 specification" do
      checks = Catalog.all("2.0")
      ids = Enum.map(checks, & &1.id)

      assert ids == Enum.uniq(ids)
      assert Enum.all?(checks, &(&1.group in Catalog.groups("2.0")))
      assert Enum.all?(checks, &Regex.match?(~r/^\d+(\.\d+)*$/, &1.section))
    end

    test "select narrows within one version" do
      assert Enum.all?(Catalog.select("2.0", ["rules"], nil), &(&1.group == "rules"))
      assert [%{id: "query.ceiling"}] = Catalog.select("2.0", nil, ["query.ceiling"])
      # search.ceiling is v1's name for it.
      assert Catalog.select("2.0", nil, ["search.ceiling"]) == []
    end
  end

  describe "CLI" do
    test "--list prints the catalogue of the version named" do
      v2 = capture_io(fn -> assert CLI.run(["--list", "--spec-version", "2.0"]) == 0 end)
      v1 = capture_io(fn -> assert CLI.run(["--list"]) == 0 end)

      assert v2 =~ "against HCP v2 (2.0-draft-3)"
      assert v2 =~ "`governance.refused.audit`"
      assert v1 =~ "against HCP v1 (1.0-draft-4)"
      refute v1 =~ "governance.refused"
    end

    test "an unknown --spec-version is a usage error" do
      output =
        capture_io(:stderr, fn -> assert CLI.run(["--list", "--spec-version", "9"]) == 2 end)

      assert output =~ "spec-version"
    end

    test "a v2 run reports the draft it checked against" do
      target = ReferenceTarget.start!(version: "2.0")

      args =
        ~w(--target #{target.base} --hook-url #{target.hook_url} --hook-secret #{target.hook_secret}) ++
          ~w(--allow-private --spec-version 2.0 --groups discovery,transport)

      output =
        capture_io(fn ->
          capture_io(:stderr, fn -> send(self(), {:status, CLI.run(args)}) end)
        end)

      assert_received {:status, 0}
      assert output =~ "(spec 2.0-draft-3)"
      assert output =~ "PASS  discovery.claims"
    end
  end

  test "docs/CHECKS-v2.md matches the catalogue (regenerate with mix hcp.checks --spec-version 2.0 > docs/CHECKS-v2.md)" do
    assert File.read!("docs/CHECKS-v2.md") == CLI.catalogue("2.0")
  end
end
