with positive_loss_loans as (

    select
        loan_id,
        loss_amount

    from {{ ref('int_loans_joined') }}

    -- Same population as mart_loss_concentration: a severity distribution over
    -- zero and negative amounts would not be a severity distribution.
    where loss_amount > 0

),


banded as (

    select
        loan_id,

        loss_amount,

        case
            when loss_amount < 10000 then 1
            when loss_amount < 25000 then 2
            when loss_amount < 50000 then 3
            when loss_amount < 100000 then 4
            else 5
        end as severity_band_order,

        -- Bands are labelled without a currency symbol because the source does
        -- not state a currency. Upper bounds are exclusive.
        case
            when loss_amount < 10000 then '0-10k'
            when loss_amount < 25000 then '10k-25k'
            when loss_amount < 50000 then '25k-50k'
            when loss_amount < 100000 then '50k-100k'
            else '100k+'
        end as severity_band

    from positive_loss_loans

),


portfolio_totals as (

    select
        count(*) as positive_loss_loan_count,

        sum(loss_amount) as portfolio_positive_loss_amount

    from banded

),


band_metrics as (

    select
        severity_band_order,

        severity_band,

        count(*) as loan_count,

        sum(loss_amount) as total_positive_loss_amount,

        avg(loss_amount) as average_positive_loss,

        median(loss_amount) as median_positive_loss

    from banded

    group by
        severity_band_order,
        severity_band

),


final as (

    select
        band_metrics.severity_band,

        band_metrics.severity_band_order,

        band_metrics.loan_count,

        band_metrics.loan_count * 1.0
            / portfolio_totals.positive_loss_loan_count
            as positive_loss_loan_share,

        band_metrics.total_positive_loss_amount,

        band_metrics.total_positive_loss_amount
            / portfolio_totals.portfolio_positive_loss_amount
            as positive_loss_amount_share,

        band_metrics.average_positive_loss,

        band_metrics.median_positive_loss

    from band_metrics

    cross join portfolio_totals

)

select *
from final
order by severity_band_order
