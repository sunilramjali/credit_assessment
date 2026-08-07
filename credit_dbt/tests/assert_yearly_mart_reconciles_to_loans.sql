-- The yearly mart must account for every dated loan, and every loss.
--
-- Nothing else in the project connects a mart total back to the rows it was
-- built from. Every other test asks whether a column is well-formed -- unique,
-- not null, in range -- and a GROUP BY that silently dropped a year would pass
-- all of them. The mart would still have unique years, non-null counts and
-- plausible rates. It would just be missing loans.
--
-- The comparison excludes rows with no received_date, because the yearly mart
-- filters those out and cannot be expected to count them. That count is
-- published separately as a data_quality KPI, so the gap stays visible.

with mart_totals as (

    select
        sum(funded_loan_count) as mart_loans,
        sum(loss_loan_count) as mart_losses

    from {{ ref('mart_portfolio_yearly') }}

),

source_totals as (

    select
        count(*) as source_loans,
        sum(cast(is_loss as integer)) as source_losses

    from {{ ref('int_loans_joined') }}

    where received_date is not null

)

select
    mart_totals.mart_loans,
    source_totals.source_loans,
    mart_totals.mart_losses,
    source_totals.source_losses

from mart_totals

cross join source_totals

where mart_totals.mart_loans <> source_totals.source_loans
    or mart_totals.mart_losses <> source_totals.source_losses
