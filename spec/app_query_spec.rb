# frozen_string_literal: true

RSpec.describe AppQuery do
  xdescribe "::[]" do
    it "resolves file from string or symbol" do
      described_class[:foo] #=> app/queries/foo.sql
      described_class["reports/weekly"] #=> app/queries/reports/weekly.sql
    end

    it "resolves erb-file if present" do
      AppQuery[:foo] #=> "/path/to/app/queries/foo.sql.erb"
    end

    it "takes file as is when file-ext" do
      AppQuery["foo.txt"] #=> "/path/to/app/queries/foo.txt"
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
end
