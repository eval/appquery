# frozen_string_literal: true

RSpec.describe AppQuery do
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
