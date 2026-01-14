# frozen_string_literal: true

RSpec.describe AppQuery::Q do
  def app_query(...)
    AppQuery(...)
  end

  def articles_query
    app_query(<<~SQL)
      with articles(id,title,published) as(
        values(1, 'First', true),
              (2, 'Second', false),
              (3, 'Third', true))
      select * from articles
    SQL
  end

  describe "#count", :db do
    specify "without select" do
      expect(articles_query.count).to eq 3
    end

    specify "with select and binds" do
      expect(articles_query.count(<<~SQL, binds: {published: true})).to eq 2
        SELECT *
        FROM :_
        WHERE published = :published
      SQL
    end
  end

  describe "#take", :db do
    specify "returns first n rows" do
      expect(articles_query.take(2).size).to eq(2)
      expect(articles_query.take(2).first).to include("title" => "First")
    end

    specify "with select and binds" do
      result = articles_query.take(1, <<~SQL, binds: {published: true})
        SELECT * FROM :_ WHERE published = :published
      SQL
      expect(result.size).to eq(1)
      expect(result.first).to include("title" => "First", "published" => true)
    end

    specify "limit is an alias" do
      expect(articles_query.limit(2)).to eq(articles_query.take(2))
    end
  end

  describe "#last", :db do
    specify "returns the last row" do
      expect(articles_query.last).to include("title" => "Third")
    end

    specify "returns nil for empty result" do
      result = articles_query.last("SELECT * FROM :_ WHERE false")
      expect(result).to be_nil
    end

    specify "with select" do
      result = articles_query.last("SELECT * FROM :_ WHERE published = true")
      expect(result).to include("title" => "Third")
    end
  end

  describe "#take_last", :db do
    specify "returns last n rows" do
      result = articles_query.take_last(2)
      expect(result.size).to eq(2)
      expect(result.map { _1["title"] }).to eq(%w[Second Third])
    end

    specify "returns empty array for empty result" do
      result = articles_query.take_last(2, "SELECT * FROM :_ WHERE false")
      expect(result).to eq([])
    end

    specify "handles n larger than result size" do
      result = articles_query.take_last(10)
      expect(result.size).to eq(3)
    end
  end

  describe "#column", :db do
    specify "quotes the column name" do
      expect(ActiveRecord::Base.connection).to receive(:quote_column_name).with("title").and_call_original
      articles_query.column("title")
    end

    specify "without select" do
      expect(articles_query.column("title")).to eq(["First", "Second", "Third"])
    end

    specify "with select and binds" do
      expect(articles_query.column(:title, <<~SQL, binds: {published: true})).to eq(["First", "Third"])
        SELECT *
        FROM :_
        WHERE published = :published
      SQL
    end

    specify "with unique: true" do
      expect(articles_query.column(:published, unique: true)).to contain_exactly(true, false)
    end
  end

  describe "#column_names", :db do
    specify "returns column names" do
      expect(articles_query.column_names).to eq(%w[id title published])
    end

    specify "works on empty results" do
      expect(app_query("SELECT 1 AS a, 2 AS b WHERE false").column_names).to eq(%w[a b])
    end
  end

  describe "#cte", :db do
    specify "focuses on the named CTE" do
      expect(articles_query.cte(:articles).count).to eq(3)
    end

    specify "raises for unknown CTE" do
      expect { articles_query.cte(:unknown) }.to raise_error(ArgumentError, /Unknown CTE/)
    end

    specify "handles quoted CTE names" do
      q = app_query(<<~SQL)
        WITH "special*name" AS (SELECT 1 AS n)
        SELECT * FROM "special*name"
      SQL
      expect(q.cte("special*name").count).to eq(1)
    end
  end

  describe "#any?", :db do
    specify "without select" do
      expect(articles_query.any?).to be
    end

    specify "with select and binds" do
      expect(articles_query.any?(<<~SQL)).to_not be
        SELECT *
        FROM :_
        WHERE published AND id in (2)
      SQL
    end
  end

  describe "#ids", :db do
    specify "without select" do
      expect(articles_query.ids).to eq([1, 2, 3])
    end

    specify "with select and binds" do
      expect(articles_query.ids(<<~SQL, binds: {published: true})).to eq([1, 3])
        SELECT *
        FROM :_
        WHERE published = :published
      SQL
    end
  end

  describe "#with_sql" do
    it "returns a new instance with the sql" do
      aq = app_query("select 1")

      bq = aq.with_sql("select 2")
      aggregate_failures do
        expect(aq.to_s).to eql "select 1"
        expect(bq.to_s).to eql "select 2"
      end
    end
  end

  describe "#with_binds" do
    it "returns a new instance with binds replaced" do
      aq = app_query("select :foo, :bar", binds: {foo: 1})

      bq = aq.with_binds(bar: 2)
      aggregate_failures do
        expect(aq.binds).to include(bar: nil)        # old stays the same
        expect(bq.binds).to include(foo: nil, bar: 2)  # new contains this
      end
    end
  end

  describe "#add_binds" do
    it "returns a new instance with binds merged" do
      aq = app_query("select :foo, :bar", binds: {foo: 1})

      bq = aq.add_binds(bar: 2)
      aggregate_failures do
        expect(aq.binds).to include(bar: nil)        # old stays the same
        expect(bq.binds).to include(foo: 1, bar: 2)  # new contains this
      end
    end
  end

  describe "#with_select" do
    it "changes the select" do
      expect(app_query("select 1").with_select("select 2")).to have_attributes(select: "select 2")
    end

    describe "sql" do
      it "appends a CTE _ for the existing query" do
        aq = app_query("select 1")

        expect(aq.with_select("select 2").to_s).to match(/WITH _ AS/)
      end

      it "stacks CTEs when chaining with_select" do
        aq = app_query("select 1").with_select("select 2")

        result = aq.with_select("select 3").to_s
        expect(result).to match(/_ AS/)      # first CTE
        expect(result).to match(/_1 AS/)     # second CTE
        expect(result).to match(/select 1/)  # original query in _ CTE
        expect(result).to match(/select 2/)  # first with_select in _1 CTE
        expect(result).to match(/select 3/)  # final SELECT
      end
    end

    it "yields new instance" do
      aq = app_query("select 1")

      expect {
        aq.with_select("select 2")
      }.to_not change(aq, :select)
    end
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

    context "helper: quote", :db do
      it "quotes" do
        expect(render_sql(<<~SQL, {})).to match(/VALUES\('Let''s learn SQL!'/)
          INSERT INTO videos (title)
          VALUES(<%= quote("Let's learn SQL!") %>)
        SQL
      end
    end

    context "helper: values", :db do
      it "generates named placeholders for an array" do
        q = app_query(<<~SQL).render({})
          INSERT INTO videos (id, title)
          <%= values([[1, "Some video"], [2, "Another video"]]) %>
        SQL

        expect(q.to_s).to match(/VALUES \(:b1, :b2\),.\(:b3, :b4\)/m)
        expect(q.binds).to eq({b1: 1, b2: "Some video", b3: 2, b4: "Another video"})
      end

      it "generates column names and placeholders for a hash" do
        q = app_query(<<~SQL).render({})
          INSERT INTO videos <%= values([{id: 1, title: "Some video"}, {id: 2, title: "Another video"}]) %>
        SQL

        expect(q.to_s).to match(/\(id, title\) VALUES \(:b1, :b2\),.\(:b3, :b4\)/m)
        expect(q.binds).to eq({b1: 1, b2: "Some video", b3: 2, b4: "Another video"})
      end

      it "handles mixed keys with NULL for missing values" do
        q = app_query(<<~SQL).render({})
          INSERT INTO articles <%= values([{title: "A"}, {title: "B", published_on: "2024-01-01"}]) %>
        SQL

        expect(q.to_s).to match(/\(title, published_on\) VALUES \(:b1, NULL\),.\(:b2, :b3\)/m)
        expect(q.binds).to eq({b1: "A", b2: "B", b3: "2024-01-01"})
      end

      it "skips columns with skip_columns: true" do
        q = app_query(<<~SQL).render({})
          SELECT * FROM articles UNION ALL <%= values([{id: 1, title: "A"}], skip_columns: true) %>
        SQL

        expect(q.to_s).to match(/UNION ALL VALUES \(:b1, :b2\)/)
        expect(q.to_s).not_to match(/\(id, title\)/)
      end

      it "can be merged with explicit named binds" do
        q = app_query(<<~SQL, binds: {id: 42}).render({})
          SELECT * FROM t WHERE id = :id
          UNION ALL
          <%= values([[1, "title"]], skip_columns: true) %>
        SQL

        expect(q.to_s).to match(/VALUES \(:b1, :b2\)/)
        expect(q.binds).to eq({id: 42, b1: 1, b2: "title"})
      end
    end

    context "helper: bind", :db do
      it "generates a named placeholder and collects the bind" do
        q = app_query(<<~SQL).render({})
          SELECT * FROM videos WHERE title = <%= bind("Some title") %>
        SQL

        expect(q.to_s).to match(/WHERE title = :b1/)
        expect(q.binds).to eq({b1: "Some title"})
      end
    end

    context "helper: order_by" do
      it "accepts a hash" do
        expect(render_sql(<<~SQL, {})).to match(/ORDER BY year DESC, month DESC/)
          SELECT *
          FROM table
          <%= order_by(year: :desc, month: :desc) %>
        SQL
      end

      it "accepts a string" do
        expect(render_sql(<<~SQL, {})).to match(/ORDER BY RANDOM()/)
          SELECT *
          FROM table
          <%= order_by("RANDOM()") %>
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

    context "helper: paginate" do
      it "generates LIMIT/OFFSET for page 1" do
        expect(render_sql(<<~SQL, {})).to match(/LIMIT 25 OFFSET 0/)
          SELECT * FROM table
          <%= paginate(page: 1, per_page: 25) %>
        SQL
      end

      it "calculates correct offset for subsequent pages" do
        expect(render_sql(<<~SQL, {})).to match(/LIMIT 25 OFFSET 25/)
          SELECT * FROM table
          <%= paginate(page: 2, per_page: 25) %>
        SQL

        expect(render_sql(<<~SQL, {})).to match(/LIMIT 10 OFFSET 20/)
          SELECT * FROM table
          <%= paginate(page: 3, per_page: 10) %>
        SQL
      end

      it "returns empty string when page is nil" do
        expect(render_sql("<%= paginate(page: nil, per_page: 25) %>", {})).to eq("")
      end

      it "raises for invalid page" do
        expect {
          render_sql("<%= paginate(page: 0, per_page: 25) %>", {})
        }.to raise_error(ArgumentError, /page must be a positive integer/)

        expect {
          render_sql("<%= paginate(page: -1, per_page: 25) %>", {})
        }.to raise_error(ArgumentError, /page must be a positive integer/)

        expect {
          render_sql("<%= paginate(page: '1', per_page: 25) %>", {})
        }.to raise_error(ArgumentError, /page must be a positive integer/)
      end

      it "raises for invalid per_page" do
        expect {
          render_sql("<%= paginate(page: 1, per_page: 0) %>", {})
        }.to raise_error(ArgumentError, /per_page must be a positive integer/)

        expect {
          render_sql("<%= paginate(page: 1, per_page: -10) %>", {})
        }.to raise_error(ArgumentError, /per_page must be a positive integer/)

        expect {
          render_sql("<%= paginate(page: 1, per_page: '25') %>", {})
        }.to raise_error(ArgumentError, /per_page must be a positive integer/)
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
    end

    it "strips quotes from quoted identifiers" do
      expect(app_query(%[with "foo" as(select 1), bar as(select 2)])).to have_attributes(cte_names: match(%w[foo bar]))
      expect(app_query(%[with "special*name" as(select 1)])).to have_attributes(cte_names: ["special*name"])
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

  describe "query execution", :db do
    def query
      app_query(<<~SQL)
        with articles(id,title,published_on) as (
        values(1, 'Some title', '2024-3-31'),
              (2, 'Other title', '2024-10-31'),
              (3, 'Moar title?', '2024-10-31')
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

      it "supports indifferent access" do
        row = query.select_one
        expect(row[:id]).to eq(row["id"])
        expect(row[:tags]).to eq(row["tags"])
      end
    end

    describe "#select_all" do
      it "supports indifferent access" do
        results = query.select_all
        row = results.first
        expect(row[:id]).to eq(row["id"])
      end

      it "supports indifferent access during iteration" do
        query.select_all.each do |row|
          expect(row[:id]).to eq(row["id"])
        end
      end
    end

    describe "#insert" do
      before do
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS videos")
        ActiveRecord::Base.connection.execute(<<~SQL)
          CREATE TABLE videos (
            id SERIAL PRIMARY KEY,
            title TEXT NOT NULL,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP NOT NULL
          )
        SQL
      end

      after do
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS videos")
      end

      it "inserts a single row" do
        q = app_query(<<~SQL)
          INSERT INTO videos (title, created_at, updated_at)
          VALUES ('Test Video', now(), now())
        SQL

        expect { q.insert }.to change {
          app_query("SELECT COUNT(*) FROM videos").select_value
        }.by(1)
      end

      it "inserts multiple rows using values helper" do
        videos = [["Let's Learn SQL"], ["O'Reilly's Tutorial"]]
        q = app_query(<<~SQL).render(videos: videos)
          INSERT INTO videos (title, created_at, updated_at)
          <%= values(videos) { |(title)| [quote(title), 'now()', 'now()'] } %>
        SQL

        expect { q.insert }.to change {
          app_query("SELECT COUNT(*) FROM videos").select_value
        }.by(2)

        titles = app_query("SELECT title FROM videos ORDER BY id").select_all.column("title")
        expect(titles).to eq(["Let's Learn SQL", "O'Reilly's Tutorial"])
      end
    end

    describe "#update" do
      before do
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS videos")
        ActiveRecord::Base.connection.execute(<<~SQL)
          CREATE TABLE videos (
            id SERIAL PRIMARY KEY,
            title TEXT NOT NULL,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP NOT NULL
          )
        SQL
      end

      after do
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS videos")
      end

      it "updates rows and returns affected count" do
        app_query("INSERT INTO videos (title, created_at, updated_at) VALUES ('Original', now(), now())").insert

        q = app_query("UPDATE videos SET title = 'Updated' WHERE title = 'Original'")
        expect(q.update).to eq(1)

        expect(app_query("SELECT title FROM videos").select_value).to eq("Updated")
      end

      it "supports named binds" do
        app_query("INSERT INTO videos (title, created_at, updated_at) VALUES ('Original', now(), now())").insert

        q = app_query("UPDATE videos SET title = :new_title WHERE title = :old_title")
        expect(q.update(binds: {new_title: "Updated", old_title: "Original"})).to eq(1)

        expect(app_query("SELECT title FROM videos").select_value).to eq("Updated")
      end
    end

    describe "#delete" do
      before do
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS videos")
        ActiveRecord::Base.connection.execute(<<~SQL)
          CREATE TABLE videos (
            id SERIAL PRIMARY KEY,
            title TEXT NOT NULL,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP NOT NULL
          )
        SQL
      end

      after do
        ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS videos")
      end

      it "deletes rows and returns affected count" do
        app_query("INSERT INTO videos (title, created_at, updated_at) VALUES ('ToDelete', now(), now())").insert

        q = app_query("DELETE FROM videos WHERE title = 'ToDelete'")
        expect(q.delete).to eq(1)

        expect(app_query("SELECT COUNT(*) FROM videos").select_value).to eq(0)
      end

      it "supports named binds" do
        app_query("INSERT INTO videos (title, created_at, updated_at) VALUES ('ToDelete', now(), now())").insert

        q = app_query("DELETE FROM videos WHERE title = :title")
        expect(q.delete(binds: {title: "ToDelete"})).to eq(1)

        expect(app_query("SELECT COUNT(*) FROM videos").select_value).to eq(0)
      end
    end

    describe "#select_all" do
      describe ":binds" do
        specify "named binds" do
          q = query.with_select(<<~SQL)
            SELECT * FROM articles
            WHERE title ILIKE :title_ilike
            ORDER BY id desc
          SQL

          expect(q.select_one(binds: {title_ilike: "%title"})).to include("title" => "Other title")
        end

        specify "binds combined with values helper" do
          q = app_query(<<~SQL).render(titles: ["More", "And even more"])
            WITH articles(id, title) AS (
              VALUES (1, 'Original')
            )
            SELECT title FROM articles WHERE id = :id
            UNION ALL
            <%= values(titles.map { [_1] }) %>
          SQL

          result = q.select_all(binds: {id: 1})
          expect(result.column("title")).to eq(["Original", "More", "And even more"])
        end
      end

      describe "select argument" do
        it "overrides the select-part" do
          expect(query.select_all("select title from articles")).to \
            include(a_hash_including("title" => "Some title"))
        end

        specify "handles binds in select" do
          expect(query.select_all(<<~SQL, binds: {ids: [1]})).to include(a_hash_including("title" => "Some title"))
            SELECT title
            FROM articles
            WHERE id = ANY(array[:ids]::int[])
          SQL
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
          expect(query.select_all("select * from :_ where id = 1", cast: true)).to \
            include(a_hash_including("tags" => %w[ruby rails]))
          expect(query.select_all(cast: true)).to \
            include(a_hash_including("tags" => %w[ruby rails]))
        end

        it do
          expect(query.select_all(cast: true)).to be_cast
        end

        it "allows for custom casting" do
          expect(query.select_all("select * from articles",
            cast: {"published_on" => ActiveRecord::Type::Date.new})).to \
              include(a_hash_including("published_on" => "2024-3-31".to_date))
        end

        it "allows symbol shorthands for types" do
          expect(query.select_all("select * from articles",
            cast: {"published_on" => :date})).to \
              include(a_hash_including("published_on" => "2024-3-31".to_date))
        end

        it "allows mixing shorthands with explicit types" do
          types = {"published_on" => :date, "id" => ActiveRecord::Type::Integer.new}
          expect(query.select_all("select * from articles", cast: types)).to \
            include(a_hash_including("published_on" => "2024-3-31".to_date, "id" => 1))
        end

        it "allows symbol keys in cast hash" do
          expect(query.select_all("select * from articles", cast: {published_on: :date})).to \
            include(a_hash_including("published_on" => "2024-3-31".to_date))
        end
      end
    end
  end

  describe "#copy_to", :db do
    before do
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS export_test")
      ActiveRecord::Base.connection.execute(<<~SQL)
        CREATE TABLE export_test (id int, name text)
      SQL
      ActiveRecord::Base.connection.execute("INSERT INTO export_test VALUES (1, 'Alice'), (2, 'Bob')")
    end

    after do
      ActiveRecord::Base.connection.execute("DROP TABLE IF EXISTS export_test")
    end

    it "returns CSV string when to: is nil" do
      result = app_query("SELECT * FROM export_test ORDER BY id").copy_to(header: true)
      expect(result).to include("id,name")
      expect(result).to include("1,Alice")
      expect(result).to include("2,Bob")
    end

    it "writes to file path" do
      path = "tmp/export_test.csv"
      bytes = app_query("SELECT * FROM export_test ORDER BY id").copy_to(dest: path)
      expect(bytes).to be > 0
      expect(File.read(path)).to include("1,Alice")
    ensure
      File.delete(path) if File.exist?(path)
    end

    it "writes to IO object and returns nil" do
      io = StringIO.new
      result = app_query("SELECT * FROM export_test ORDER BY id").copy_to(dest: io)
      expect(result).to be_nil
      expect(io.string).to include("1,Alice")
    end

    it "supports binds" do
      result = app_query("SELECT * FROM export_test WHERE id = :id").copy_to(binds: {id: 1})
      expect(result).to include("Alice")
      expect(result).not_to include("Bob")
    end

    it "supports custom delimiter" do
      result = app_query("SELECT * FROM export_test ORDER BY id").copy_to(delimiter: :tab, header: false)
      expect(result).to include("1\tAlice")
    end

    it "supports format: :text" do
      result = app_query("SELECT * FROM export_test ORDER BY id").copy_to(format: :text)
      expect(result).to include("1\tAlice")
    end

    it "supports format: :binary" do
      result = app_query("SELECT * FROM export_test ORDER BY id").copy_to(format: :binary)
      # PostgreSQL binary format starts with "PGCOPY\n\xff\r\n\0"
      expect(result).to start_with("PGCOPY\n")
    end

    it "supports select override parameter" do
      result = app_query("SELECT * FROM export_test").copy_to("SELECT * FROM :_ WHERE id = 1", header: false)
      expect(result.strip).to eq("1,Alice")
    end

    it "raises error for invalid format" do
      expect { app_query("SELECT 1").copy_to(format: :json) }.to raise_error(
        ArgumentError, /Invalid format: :json/
      )
    end

    it "raises error for invalid delimiter" do
      expect { app_query("SELECT 1").copy_to(delimiter: :colon) }.to raise_error(
        ArgumentError, /Invalid delimiter: :colon/
      )
    end
  end

  describe "#copy_to with non-PostgreSQL adapter" do
    it "raises error when adapter doesn't support COPY" do
      raw_conn = double("raw_connection")
      allow(raw_conn).to receive(:respond_to?).with(:copy_data).and_return(false)
      allow(ActiveRecord::Base.connection).to receive(:raw_connection).and_return(raw_conn)

      expect { app_query("SELECT 1").copy_to }.to raise_error(
        AppQuery::Error, /copy_to requires PostgreSQL/
      )
    end
  end
end
