# frozen_string_literal: true

RSpec.describe AppQuery::Q do
  def q(...)
    described_class.new(...)
  end

  describe "#replace_select" do
    it "replaces" do
      expect(q("select 1").replace_select("select * from other")).to eq "select * from other"
    end

    it "replaces" do
      expect(q("-- some comment\nselect 1").replace_select("select * from other")).to eq "select * from other"
    end
  end

  describe "#replace_cte" do
    # query.replace_cte("foo", select: "select 1")
  end

  describe "prepend_cte" do

  end

  describe "append_cte" do

  end

  describe "#as_cte" do
    it "wraps the sql in a CTE named 'result'" do
      expect(q("select 1").as_cte.to_s).to match /WITH "result"/
    end

    it "allows for customizing a select" do
      expect(q("select 1").as_cte(select: "select COUNT() from result").to_s).to match /select COUNT/
    end
  end
end
