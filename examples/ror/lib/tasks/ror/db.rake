namespace :ror do
  namespace :db do
    def fixture_path(f)
      Rails.root / "spec" / "fixtures" / "#{f}.yml"
    end

    # write_fixture!(:articles, contents)
    def write_fixture!(file, contents)
      File.write(fixture_path(file), contents)
    end

    def report_progress(k, &block)
      print "\n== Fixturifying #{k}..."
      yield
      puts "done! =="
    end

    desc "Turn the current dev-database into fixtures"
    task fixturify: :environment do
      report_progress(:tags) do
        write_fixture!(:tags, Tag.all.map do
          _1.attributes.slice("name")
        end.sort_by { _1["name"] }.index_by { _1["name"] }.to_yaml)
      end

      report_progress(:articles) do
        write_fixture!(:articles, Article.all.map do |article|
          article.attributes.tap do |atts|
            atts["tags"] = article.tags.map(&:name).join(",")
          end.slice("title", "published_on", "tags", "id")
        end.index_by { _1["id"] }.to_yaml)
      end
    end
  end
end
