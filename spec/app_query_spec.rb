# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe AppQuery do
  def app_query(...)
    AppQuery(...)
  end

  describe "::[]" do
    around do |example|
      Dir.mktmpdir do |dir|
        @query_path = dir
        described_class.configure { |cfg| cfg.query_path = dir }
        example.run
      end
    end

    after { described_class.reset_configuration! }

    def write_query(filename, content)
      path = File.join(@query_path, filename)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

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

  describe "::table", :db do
    specify "creates query selecting from table" do
      q = described_class.table(:products)
      expect(q.to_s).to eq('SELECT * FROM "products"')
    end

    specify "can be chained with other methods" do
      # pg_tables is a system view that always exists
      expect(described_class.table(:pg_tables).any?).to be true
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

  describe AppQuery::Result do
    let(:result) { described_class.new(%w[id name], [[1, "Alice"], [2, "Bob"]]) }

    describe "#column" do
      specify "accepts string" do
        expect(result.column("name")).to eq(%w[Alice Bob])
      end

      specify "accepts symbol" do
        expect(result.column(:name)).to eq(%w[Alice Bob])
      end

      specify "returns first column when no name given" do
        expect(result.column).to eq([1, 2])
      end

      specify "raises for unknown column" do
        expect { result.column(:unknown) }.to raise_error(ArgumentError, /Unknown column/)
      end
    end
  end
end
