-- Instantiate this query with AppQuery["recent_articles"]
WITH settings(default_published_after) as (
  values(datetime('now', '-3 year'))
),

recent_articles(article_id, article_title, article_published_on, article_url) AS (
  SELECT id, title, published_on, url
  FROM articles
  RIGHT JOIN settings
  WHERE published_on > COALESCE(?1, settings.default_published_after))
),

tags_by_article(article_id, tags) AS (
  SELECT articles_tags.article_id,
    json_group_array(tags.name) AS tags
  FROM articles_tags
  JOIN tags ON articles_tags.tag_id = tags.id
  GROUP BY articles_tags.article_id
)

SELECT recent_articles.*,
       group_concat(json_each.value, ',' ORDER BY value ASC) tags
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
