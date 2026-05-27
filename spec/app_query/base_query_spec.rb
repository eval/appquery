# frozen_string_literal: true

RSpec.describe AppQuery::BaseQuery, :db do
  let(:articles_sql) {
    <<~SQL
      with articles(id,title,published) as(
        values(1, 'First', true),
              (2, 'Second', false),
              (3, 'Third', true))
      select * from articles
    SQL
  }

  describe "Mappable installs a row_builder on Q" do
    before do
      stub_const("ArticlesQuery", Class.new(described_class) {
        include AppQuery::Mappable
      })
      ArticlesQuery.const_set(:Item, Data.define(:id, :title, :published))
      sql = articles_sql
      ArticlesQuery.define_method(:base_query) { AppQuery(sql) }
    end

    it "returns Items from .entries" do
      expect(ArticlesQuery.new.entries.first).to be_a(ArticlesQuery::Item)
    end

    it "returns an Item from .first" do
      expect(ArticlesQuery.new.first).to be_a(ArticlesQuery::Item)
    end

    it "returns an Item from .last" do
      expect(ArticlesQuery.new.last).to be_a(ArticlesQuery::Item)
    end

    it "returns Items from .take(n)" do
      expect(ArticlesQuery.new.take(2).map(&:class).uniq).to eq([ArticlesQuery::Item])
    end

    it "returns Items from .take_last(n)" do
      expect(ArticlesQuery.new.take_last(2).map(&:class).uniq).to eq([ArticlesQuery::Item])
    end

    it "returns an Item from .with_select(non_nil).first" do
      item = ArticlesQuery.new.with_select("SELECT * FROM :_ WHERE id = 1").first
      expect(item).to be_a(ArticlesQuery::Item)
      expect(item.title).to eq("First")
    end

    it "returns Items from .select_all.entries" do
      expect(ArticlesQuery.new.select_all.entries.first).to be_a(ArticlesQuery::Item)
    end

    it "returns an Item from .select_one" do
      expect(ArticlesQuery.new.select_one).to be_a(ArticlesQuery::Item)
    end

    it ".raw bypasses mapping" do
      row = ArticlesQuery.new.raw.entries.first
      expect(row).to be_a(Hash)
      expect(row["title"]).to eq("First")
    end

    it "honors map_to :symbol" do
      stub_const("Article", Data.define(:id, :title, :published))
      ArticlesQuery.map_to :article
      expect(ArticlesQuery.new.first).to be_a(Article)
    end

    it "honors map_to ClassRef" do
      klass = Data.define(:id, :title, :published)
      stub_const("Other", klass)
      ArticlesQuery.map_to klass
      expect(ArticlesQuery.new.first).to be_a(klass)
    end

    it "returns raw hashes when neither map_to nor Item is set" do
      stub_const("NoMapQuery", Class.new(described_class) {
        include AppQuery::Mappable
      })
      sql = articles_sql
      NoMapQuery.define_method(:base_query) { AppQuery(sql) }
      expect(NoMapQuery.new.first).to be_a(Hash)
    end
  end

  describe "Paginatable stacks with Mappable" do
    before do
      stub_const("PagQuery", Class.new(described_class) {
        include AppQuery::Paginatable
        include AppQuery::Mappable
      })
      PagQuery.const_set(:Item, Data.define(:id, :title, :published))
      sql = articles_sql
      PagQuery.define_method(:base_query) { AppQuery(sql) }
    end

    it "returns a PaginatedResult whose records are Items" do
      result = PagQuery.new.paginate(page: 1, per_page: 2).entries
      expect(result).to be_a(AppQuery::Paginatable::PaginatedResult)
      expect(result.first).to be_a(PagQuery::Item)
      expect(result.to_a.map(&:class).uniq).to eq([PagQuery::Item])
    end

    it "unpaginated returns plain mapped array" do
      result = PagQuery.new.entries
      expect(result).to be_an(Array)
      expect(result.first).to be_a(PagQuery::Item)
    end
  end

  describe "lightweight AppQuery() path is unchanged" do
    it "returns Hash without any row_builder set" do
      row = AppQuery(<<~SQL).first
        with articles(id,title) as(values(1, 'First'))
        select * from articles
      SQL
      expect(row).to be_a(Hash)
      expect(row["title"]).to eq("First")
    end
  end

  describe "Q#row_builder pipeline" do
    it "propagates through with_select, with_binds, add_binds, with_sql, with_cast" do
      q = AppQuery("select 1 as x")
      q.row_builder << ->(row) { row.merge("touched" => true) }

      [q.with_select("SELECT * FROM :_"), q.with_binds, q.add_binds, q.with_sql("select 2 as x"), q.with_cast(false)].each do |child|
        expect(child.row_builder).to be_a(AppQuery::RowBuilder)
        expect(child.row_builder.call({"x" => 1})).to include("touched" => true)
      end
    end

    it "child pipeline is independent of parent after deep_dup" do
      parent = AppQuery("select 1 as x")
      parent.row_builder << ->(row) { row.merge("a" => 1) }
      child = parent.with_select("SELECT * FROM :_")

      child.row_builder << ->(row) { row.merge("b" => 2) }

      expect(parent.row_builder.call({})).to eq({"a" => 1}.with_indifferent_access)
      expect(child.row_builder.call({})).to eq({"a" => 1, "b" => 2}.with_indifferent_access)
    end

    it "two row-level middlewares chain in include order" do
      stamp_first = Module.new do
        extend ActiveSupport::Concern

        define_method(:query) do
          @query ||= super().tap { |q| q.row_builder << ->(row) { row.merge("a" => 1) } }
        end
      end
      stamp_second = Module.new do
        extend ActiveSupport::Concern

        define_method(:query) do
          @query ||= super().tap { |q| q.row_builder << ->(row) { row.merge("b" => row["a"].to_i + 1) } }
        end
      end

      sql = articles_sql
      stub_const("ChainQuery", Class.new(described_class) {
        include stamp_first
        include stamp_second
      })
      ChainQuery.define_method(:base_query) { AppQuery(sql) }

      row = ChainQuery.new.first
      expect(row["a"]).to eq(1)   # first include ran first
      expect(row["b"]).to eq(2)   # last include saw "a" already set
    end
  end
end
