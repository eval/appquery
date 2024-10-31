-- Instantiate this query with AppQuery["some_articles"]

WITH articles(article_id, article_title) AS (
  VALUES (1, 'Some title'),
         (2, 'Another article')
)

SELECT *
FROM artciles
