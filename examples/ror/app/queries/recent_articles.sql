-- Instantiate this query with AppQuery["recent_articles"]

/*
Query that selects articles recently published.

binds:
  1. string representing the minimum articles.published_on date (default: `3 years ago`)
    e.g. `1.year.ago`, `"2024-1-1"`.
  2. string that should match a tag of an article
    e.g. `"%8x"` would select an article whose tags contain the tag 'release:8x'.
*/
WITH settings(default_min_published_on) as (
  values(datetime('now', '-6 months'))
),

recent_articles(article_id, article_title, article_published_on, article_url) AS (
  SELECT id, title, published_on, url
  FROM articles
  RIGHT JOIN settings
  WHERE published_on > COALESCE(?1, settings.default_min_published_on)
),

tags_by_article(article_id, tags) AS (
  SELECT articles_tags.article_id,
    json_group_array(tags.name) AS tags
  FROM articles_tags
  JOIN tags ON articles_tags.tag_id = tags.id
  GROUP BY articles_tags.article_id
)

SELECT recent_articles.*,
       group_concat(json_each.value, ',' ORDER BY value ASC) tags_str
FROM recent_articles
JOIN tags_by_article USING(article_id),
  json_each(tags)
WHERE EXISTS (
  SELECT 1
  FROM json_each(tags)
  WHERE json_each.value LIKE ?2 OR ?2 IS NULL
)
GROUP BY recent_articles.article_id
ORDER BY recent_articles.article_published_on
