with concentration as (

    select * from {{ ref('mart_loss_concentration') }}

),


thresholds as (

    select *
    from (
        values
            (0.01),
            (0.05),
            (0.10),
            (0.20)
    ) as t (top_share_threshold)

),


-- ceil, not floor or a cumulative-share filter. ceil answers "the smallest set
-- of largest loans covering at least this share of loans", which is what "the
-- top 1%" means in normal use. It never returns an empty set, and it gives an
-- exact integer loan count that is reproducible and easy to state. Taking only
-- rows whose cumulative share stays strictly below the threshold would
-- under-cover every band and could select zero loans on a small population.
threshold_cutoffs as (

    select
        thresholds.top_share_threshold,

        max(concentration.positive_loss_loan_count) as positive_loss_loan_population,

        max(concentration.portfolio_positive_loss_amount) as portfolio_positive_loss_amount,

        cast(
            ceil(
                max(concentration.positive_loss_loan_count)
                * thresholds.top_share_threshold
            ) as integer
        ) as loan_cutoff

    from thresholds

    cross join concentration

    group by thresholds.top_share_threshold

),


final as (

    select
        threshold_cutoffs.top_share_threshold,

        threshold_cutoffs.loan_cutoff as positive_loss_loan_count,

        threshold_cutoffs.positive_loss_loan_population,

        -- The share of loans actually covered. Differs slightly from
        -- top_share_threshold because ceil rounds up to a whole loan.
        threshold_cutoffs.loan_cutoff * 1.0
            / threshold_cutoffs.positive_loss_loan_population
            as actual_loan_share,

        sum(concentration.loss_amount) as loss_amount,

        sum(concentration.loss_amount)
            / threshold_cutoffs.portfolio_positive_loss_amount
            as loss_share

    from threshold_cutoffs

    join concentration
        on concentration.loss_rank <= threshold_cutoffs.loan_cutoff

    group by
        threshold_cutoffs.top_share_threshold,
        threshold_cutoffs.loan_cutoff,
        threshold_cutoffs.positive_loss_loan_population,
        threshold_cutoffs.portfolio_positive_loss_amount

)

select *
from final
order by top_share_threshold
