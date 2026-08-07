-- `mart_portfolio_kpis_wide` must always be exactly one row.
--
-- A scorecard aggregates whatever rows it is given, so a second row would not
-- error anywhere: it would silently double every SUM and quietly halve nothing.
-- The wide model has no GROUP BY, so this should be structurally impossible --
-- which is exactly why it is worth asserting rather than assuming.

select count(*) as row_count

from {{ ref('mart_portfolio_kpis_wide') }}

having count(*) <> 1
