with loans as (

    select
        loan_id,
        received_date,
        is_loss,
        loss_amount

    from {{ ref('int_loans_joined') }}

),

yearly_summary as (

    select
        extract(year from received_date)::integer as origination_year,

        count(distinct loan_id) as funded_loan_count,

        sum(cast(is_loss as integer)) as loss_loan_count,

        avg(cast(is_loss as integer)) as observed_loss_rate,

        sum(coalesce(loss_amount, 0)) as total_recorded_loss_amount,

        sum(
            case
                when loss_amount > 0 then loss_amount
                else 0
            end
        ) as total_positive_loss_amount,

        avg(coalesce(loss_amount, 0)) as average_loss_per_funded_loan,

        avg(
            case
                when is_loss = true then loss_amount
            end
        ) as average_loss_severity,

        median(
            case
                when is_loss = true then loss_amount
            end
        ) as median_loss_severity,

        max(loss_amount) as maximum_loss_amount

    from loans

    where received_date is not null

    group by 1

)

select *
from yearly_summary
order by origination_year