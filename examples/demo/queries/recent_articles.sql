WITH settings(published_since) as (
  values(COALESCE(:since, datetime('now', '-6 months')))
),

recent_articles(article_id, article_title, article_published_on, article_url) AS (
  SELECT id, title, published_on, url
  FROM articles
  RIGHT JOIN settings
  WHERE published_on >= settings.published_since
),

tags_by_article(article_id, tags) AS (
  SELECT articles_tags.article_id,
    json_group_array(tags.name) AS tags
  FROM articles_tags
  JOIN tags ON articles_tags.tag_id = tags.id
  GROUP BY articles_tags.article_id
)

SELECT recent_articles.article_id AS id,
       recent_articles.article_title AS title,
       recent_articles.article_published_on AS published_on,
       recent_articles.article_url AS url,
       tags,
       group_concat(json_each.value, ',' ORDER BY value ASC) tags_str
FROM recent_articles
JOIN tags_by_article USING(article_id),
  json_each(tags)
WHERE EXISTS (
  SELECT 1
  FROM json_each(tags)
  WHERE json_each.value LIKE :tag OR :tag IS NULL
)
GROUP BY recent_articles.article_id
ORDER BY recent_articles.article_published_on desc
