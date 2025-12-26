# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe AppQuery do
  def app_query(...)
    AppQuery(...)
  end

  shared_context "with query path" do
    around do |example|
      Dir.mktmpdir do |dir|
        @query_path = dir
        described_class.configure { |cfg| cfg.query_path = dir }
        example.run
      end
    end

    after { described_class.reset_configuration! }

    def write_query(filename, content = "SELECT 1")
      path = File.join(@query_path, filename)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
  end

  describe "::[]" do
    include_context "with query path"

    describe "default binds" do
      it "initializes defaults binds" do
        expect(app_query("select :id").binds).to eql(id: nil)
      end

      it "initializes defaults binds with the binds providec" do
        expect(app_query("select :foo, :bar", binds: {foo: 1}).binds).to eql(foo: 1, bar: nil)
      end
    end

    describe "query resolving" do
      it "resolves .sql file from string or symbol" do
        write_query("foo.sql", "SELECT 1")

        expect(described_class[:foo].to_s).to eq("SELECT 1")
        expect(described_class["foo"].to_s).to eq("SELECT 1")
      end

      it "resolves .sql.erb file when .sql doesn't exist" do
        write_query("bar.sql.erb", "SELECT <%= 1 + 1 %>")

        expect(described_class[:bar].to_s).to eq("SELECT <%= 1 + 1 %>")
      end

      it "raises error when both .sql and .sql.erb exist" do
        write_query("ambiguous.sql", "SELECT 'sql'")
        write_query("ambiguous.sql.erb", "SELECT 'erb'")

        expect { described_class[:ambiguous] }.to raise_error(
          AppQuery::Error, /Ambiguous query name/
        )
      end

      it "takes file as is when extension provided" do
        write_query("custom.txt", "SELECT 'custom'")

        expect(described_class["custom.txt"].to_s).to eq("SELECT 'custom'")
      end

      it "supports subdirectories" do
        write_query("reports/weekly.sql", "SELECT 'weekly'")

        expect(described_class["reports/weekly"].to_s).to eq("SELECT 'weekly'")
      end
    end
  end

  describe "configuration" do
    before { described_class.reset_configuration! }

    it "can be configured" do
      expect {
        described_class.configure { |cfg| cfg.query_path = "foo" }
      }.to change(described_class.configuration, :query_path)
    end

    it "has certain defaults" do
      expect(described_class.configuration).to have_attributes("query_path" => "app/queries")
    end
  end

  describe "::queries" do
    include_context "with query path"

    it "returns empty array when no queries exist" do
      expect(described_class.queries).to eq([])
    end

    it "finds .sql files" do
      write_query("simple.sql")

      result = described_class.queries
      expect(result).to include(a_hash_including(name: "simple", erb: false))
    end

    it "finds .sql.erb files" do
      write_query("dynamic.sql.erb")

      result = described_class.queries
      expect(result).to include(a_hash_including(name: "dynamic", erb: true))
    end

    it "includes subdirectories in name" do
      write_query("reports/weekly.sql")

      result = described_class.queries
      expect(result).to include(a_hash_including(name: "reports/weekly"))
    end

    it "returns absolute path" do
      write_query("test.sql")

      result = described_class.queries.first
      expect(result[:path]).to start_with("/")
      expect(result[:path]).to end_with("test.sql")
    end

    it "sorts by name" do
      write_query("zebra.sql")
      write_query("alpha.sql")

      names = described_class.queries.map { |q| q[:name] }
      expect(names).to eq(%w[alpha zebra])
    end
  end
end
