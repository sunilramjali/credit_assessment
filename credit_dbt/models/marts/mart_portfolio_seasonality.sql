with loans as (

    select
        loan_id,
        received_date,
        is_loss,
        loss_amount

    from {{ ref('int_loans_joined') }}

),

monthly_summary as (

    select
        extract(year from received_date)::integer as origination_year,

        extract(month from received_date)::integer as origination_month_number,

        strftime(received_date, '%b') as origination_month_name,

        date_trunc('month', received_date)::date as origination_month_start,

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
        ) as median_loss_severity

    from loans

    where received_date is not null

    group by
        1,
        2,
        3,
        4

),

final as (

    select
        cast(origination_year as varchar)
            || '-'
            || lpad(
                cast(origination_month_number as varchar),
                2,
                '0'
            ) as origination_year_month_key,

        origination_year,
        origination_month_number,
        origination_month_name,
        origination_month_start,
        funded_loan_count,
        loss_loan_count,
        observed_loss_rate,
        total_recorded_loss_amount,
        total_positive_loss_amount,
        average_loss_per_funded_loan,
        average_loss_severity,
        median_loss_severity

    from monthly_summary

)

select *
from final
order by
    origination_year,
    origination_month_number