with loans as (

    select
        loan_id,
        received_date,
        is_loss,
        loss_amount

    from {{ ref('int_loans_joined') }}

),

quarterly_summary as (

    select
        extract(year from received_date)::integer as origination_year,

        extract(quarter from received_date)::integer as origination_quarter_number,

        'Q' || cast(
            extract(quarter from received_date) as varchar
        ) as origination_quarter_name,

        date_trunc('quarter', received_date)::date as origination_quarter_start,

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
            || origination_quarter_name
            as origination_year_quarter_key,

        origination_year,
        origination_quarter_number,
        origination_quarter_name,
        origination_quarter_start,
        funded_loan_count,
        loss_loan_count,
        observed_loss_rate,
        total_recorded_loss_amount,
        total_positive_loss_amount,
        average_loss_per_funded_loan,
        average_loss_severity,
        median_loss_severity

    from quarterly_summary

)

select *
from final
order by
    origination_year,
    origination_quarter_number
