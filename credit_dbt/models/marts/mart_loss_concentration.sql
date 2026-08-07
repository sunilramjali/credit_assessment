with positive_loss_loans as (

    select
        loan_id,
        received_date,
        extract(year from received_date)::integer as origination_year,
        loss_amount

    from {{ ref('int_loans_joined') }}

    -- The concentration question is about how realised money is allocated, so
    -- the population is loans that actually lost money. This is a different
    -- population from is_loss = true, and deliberately so: 133 loans lost money
    -- while flagged as no loss, and 20 loans are flagged as loss with a zero or
    -- negative amount. Source values are read as given, never corrected.
    where loss_amount > 0

),


ranked as (

    select
        loan_id,
        received_date,
        origination_year,
        loss_amount,

        -- loan_id breaks ties so the ordering is deterministic. Without it,
        -- equal loss_amounts could rank differently between builds and the
        -- cumulative curve would not be reproducible.
        row_number() over (
            order by loss_amount desc, loan_id
        ) as loss_rank,

        count(*) over () as positive_loss_loan_count,

        sum(loss_amount) over () as portfolio_positive_loss_amount,

        sum(loss_amount) over (
            order by loss_amount desc, loan_id
            rows between unbounded preceding and current row
        ) as cumulative_positive_loss_amount

    from positive_loss_loans

),


final as (

    select
        loan_id,
        received_date,
        origination_year,
        loss_amount,
        loss_rank,
        positive_loss_loan_count,

        -- Equal to loss_rank by construction. Kept under its own name because
        -- a chart axis reads better as a cumulative count than as a rank.
        loss_rank as cumulative_positive_loss_loan_count,

        loss_rank * 1.0
            / positive_loss_loan_count
            as cumulative_positive_loss_loan_share,

        portfolio_positive_loss_amount,

        cumulative_positive_loss_amount,

        cumulative_positive_loss_amount
            / portfolio_positive_loss_amount
            as cumulative_positive_loss_share

    from ranked

)

select *
from final
order by loss_rank
