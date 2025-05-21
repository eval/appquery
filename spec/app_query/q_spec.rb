# frozen_string_literal: true

RSpec.describe AppQuery::Q do
  def app_query(...)
    AppQuery(...)
  end

  describe "#render" do
    def render_sql(sql, render_opts)
      app_query(sql).render(render_opts).to_s
    end

    it "allows for local and instance variables" do
      expect(render_sql(<<~SQL, table: :foo)).to match(/SELECT \* FROM foo$/)
        SELECT * FROM <%= table %>
        <% if @limit -%>
        LIMIT <%= @limit %>
        <% end -%>
      SQL
    end

    it "raises when not all local variables are provided" do
      expect {
        render_sql(<<~SQL, colum: :id) # typo
          SELECT *
          FROM some_table
          ORDER BY <%= column %> desc
        SQL
      }.to raise_error(NameError, /undefined local variable or method [`']column'/)
    end

    it "raises AppQuery::UnrenderedQueryError when select-ing using unrendered query" do
      expect {
        app_query("select * from <%= table %>").select_all
      }.to raise_error(AppQuery::UnrenderedQueryError, /Query is ERB/)
    end

    context "helper: order_by" do
      it "accepts a hash" do
        expect(render_sql(<<~SQL, {})).to match(/ORDER BY year DESC, month DESC/)
          SELECT *
          FROM table
          <%= order_by(year: :desc, month: :desc) %>
        SQL
      end

      it "requires non-blank hash" do
        expect {
          render_sql(<<~SQL, order: {})
            SELECT *
            FROM table
            <%= order_by(order) %>
          SQL
        }.to raise_error(ArgumentError, /Provide columns to sort by/)
      end

      it "can be made optional" do
        expect(render_sql(<<~SQL, order: {})).to match(/SELECT \* FROM table$/)
          SELECT * FROM table
          <%= @order.presence && order_by(order) %>
        SQL
      end
    end
  end

  # TODO select_all with sql that needs rendering, raises error

  describe "#select" do
    it "finds the select-part of the query" do
      expect(app_query("select 1")).to have_attributes(select: "select 1")
      expect(app_query("")).to have_attributes(select: "")
      expect(app_query("with foo AS(select 1) select * from foo")).to \
        have_attributes(select: "select * from foo")
    end
  end

  describe "#recursive?" do
    it "indicates if it's recursive" do
      expect(app_query("WITH foo AS(select 1) select 1")).to have_attributes(recursive?: false)
      expect(app_query("select 1")).to have_attributes(recursive?: false)
      expect(app_query("with recursive foo as(select 1) select 2")).to have_attributes(recursive?: true)
    end
  end

  describe "#cte_names" do
    it "shows the correct names in the original order" do
      expect(app_query("")).to have_attributes(cte_names: match([]))
      expect(app_query("with foo as(select 1), bar as(select 2)")).to have_attributes(cte_names: match(%w[foo bar]))
      expect(app_query(%[with "foo" as(select 1), bar as(select 2)])).to have_attributes(cte_names: match(%w["foo" bar]))
    end
  end

  describe "#with_select" do
    it "changes the select" do
      expect(app_query("select 1").with_select("select 2")).to have_attributes(select: "select 2")
    end

    it "yields new instance" do
      aq = app_query("select 1")

      expect {
        aq.with_select("select 2")
      }.to_not change(aq, :select)
    end
  end

  describe "#prepend_cte" do
    it "puts a CTE in front" do
      expect(app_query("select 1").prepend_cte("foo AS(select 2)")).to have_attributes(cte_names: %w[foo])
      expect(app_query("with bar as(select 1) select 2").prepend_cte("foo AS(select 2)")).to \
        have_attributes(cte_names: %w[foo bar])
    end

    it "verifies the sql to prepend" do
      expect {
        app_query("select 1").prepend_cte("foo")
      }.to raise_error(AppQuery::Tokenizer::LexError)
    end

    it "prepends RECURSIVE correctly if needed" do
      aq = app_query("select 1")

      expect(aq.prepend_cte("recursive foo as(select 2)")).to have_attributes(recursive?: true)

      aq2 = app_query("WITH recUrsIve files as(select 1) select 1").prepend_cte("recursive foo as(select 2)")
      expect(aq2).to have_attributes(sql: match(/recUrsIve/))
      expect(aq2).not_to have_attributes(sql: match(/recursive/))
    end
  end

  describe "#append_cte" do
    # TODO raises when ctes clashing?

    it "puts a CTE at the end" do
      expect(app_query("select 1").append_cte("foo AS(select 2)")).to have_attributes(cte_names: %w[foo])
      expect(app_query("with foo as(select 1) select 2").append_cte("bar AS(select 2)")).to \
        have_attributes(cte_names: %w[foo bar])
    end

    it "verifies the sql to append" do
      expect {
        app_query("select 1").append_cte("foo")
      }.to raise_error(AppQuery::Tokenizer::LexError)
    end

    it "prepends RECURSIVE correctly if needed" do
      aq = app_query("select 1")

      expect(aq.append_cte("recursive foo as(select 2)")).to have_attributes(recursive?: true)

      aq2 = app_query("WITH recUrsIve files as(select 1) select 1").append_cte("recursive foo as(select 2)")
      expect(aq2).to have_attributes(sql: match(/recUrsIve/))
      expect(aq2).not_to have_attributes(sql: match(/recursive/))
    end
  end

  describe "#replace_cte" do
    it "replaces an existing cte" do
      aq = app_query("with foo as(select 'original')").replace_cte("foo as(select 'replaced')")

      expect(aq).to_not have_attributes(sql: match(/original/))
      expect(aq).to have_attributes(sql: match(/replaced/))
    end

    it "prepends RECURSIVE if provided" do
      aq = app_query("with foo as(select 'original')").replace_cte("recursive foo as(select 'replaced')")

      expect(aq).to have_attributes(sql: match(/recursive/))
    end
  end

  describe "query execution" do
    before { ActiveRecord::Base.establish_connection(url: ENV["SPEC_DATABASE_URL"]) }

    def query
      app_query(<<~SQL)
        with articles(id,title,published_on) as (
        values(1, 'Some title', '2024-3-31'),
              (2, 'Other title', '2024-10-31')
        )
        select *
        from (values(1, array['ruby','rails']),
                    (2, array['Clojure', 'Babashka'])) article_tags(id,tags)
      SQL
    end

    describe "#select_one" do
      it "casts" do
        expect(query.select_one(cast: true)).to include("tags" => %w[ruby rails])
      end
    end

    describe "#select_all" do
      describe "keywords" do
        it "accepts :select" do
          expect(query.select_all(select: "select title from articles")).to \
            include(a_hash_including("title" => "Some title"))
        end
      end

      describe "cast" do
        context "results having one column" do
          # this is special in Rails :(
          # irb(main):013> ActiveRecord::Base.connection.select_all("select array[1,2]").rows
          # => [["{1,2}"]]
          # irb(main):014> ActiveRecord::Base.connection.select_all("select array[1,2]").cast_values
          # => [[1, 2]]

          it "correctly casts one column, one row" do
            expect(app_query(<<~SQL).select_one(cast: true)).to include("a" => %w[1 2])
              select ARRAY['1', '2'] a
            SQL
          end

          it "correctly casts one column, multiple rows" do
            types = {"id" => ActiveRecord::Type::Integer.new}

            expect(app_query(<<~SQL).select_all(cast: types)).to include("id" => 3)
              select * from (values('1'), ('2'), ('3')) foo(id)
            SQL
          end
        end

        it "casts values correctly" do
          expect(query.select_all(select: "select * from _ where id = 1", cast: true)).to \
            include(a_hash_including("tags" => %w[ruby rails]))
          expect(query.select_all(cast: true)).to \
            include(a_hash_including("tags" => %w[ruby rails]))
        end

        it do
          expect(query.select_all(cast: true)).to be_cast
        end

        it "allows for custom casting" do
          expect(query.select_all(select: "select * from articles",
            cast: {"published_on" => ActiveRecord::Type::Date.new})).to \
              include(a_hash_including("published_on" => "2024-3-31".to_date))
        end
      end
    end
  end
end
