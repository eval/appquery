class InitialSchema < ActiveRecord::Migration[8.0]
  def change
    create_table "articles", force: :cascade do |t|
      t.string "title"
      t.string "url"
      t.date "published_on"
      t.belongs_to "author"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end

    create_table "authors", force: :cascade do |t|
      t.string "name"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end

    create_table "tags", force: :cascade do |t|
      t.string "name"
      t.datetime "created_at", null: false
      t.datetime "updated_at", null: false
    end

    create_table "articles_tags", id: false do |t|
      t.belongs_to "article"
      t.belongs_to "tag"
    end
  end
end
