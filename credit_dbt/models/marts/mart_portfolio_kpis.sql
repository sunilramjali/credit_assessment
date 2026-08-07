{% set kpis = kpi_definitions() %}


with loans as (

    select
        loan_id,
        received_date,
        is_loss,
        loss_amount

    from {{ ref('int_loans_joined') }}

),


portfolio_metrics as (

    select

        -- volume
        count(distinct loan_id) as funded_loan_count,

        min(received_date) as first_origination_date,

        max(received_date) as last_origination_date,

        date_diff(
            'day',
            min(received_date),
            max(received_date)
        ) as origination_window_days,

        count(distinct received_date) as distinct_origination_days,

        -- loss frequency
        sum(cast(is_loss as integer)) as loss_loan_count,

        sum(
            case
                when is_loss = false then 1
                else 0
            end
        ) as non_loss_loan_count,

        avg(cast(is_loss as integer)) as portfolio_loss_rate,

        -- loss severity
        sum(coalesce(loss_amount, 0)) as total_recorded_loss_amount,

        sum(
            case
                when loss_amount > 0 then loss_amount
                else 0
            end
        ) as total_positive_loss_amount,

        sum(
            case
                when loss_amount < 0 then loss_amount
                else 0
            end
        ) as total_net_recovery_amount,

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

        max(loss_amount) as maximum_loss_amount,

        -- data quality
        sum(
            case
                when loss_amount is not null
                    and is_loss <> (loss_amount > 0) then 1
                else 0
            end
        ) as label_conflict_loan_count,

        avg(
            case
                when loss_amount is not null
                    and is_loss <> (loss_amount > 0) then 1.0
                else 0.0
            end
        ) as label_conflict_rate,

        sum(
            case
                when loss_amount < 0 then 1
                else 0
            end
        ) as net_recovery_loan_count,

        sum(
            case
                when loss_amount is null then 1
                else 0
            end
        ) as missing_loss_amount_count,

        sum(
            case
                when received_date is null then 1
                else 0
            end
        ) as missing_received_date_count

    from loans

),


-- The two comparison windows are anchored on the newest date in the data, not
-- on today. The dataset is static, so "the last 12 months" has to mean the last
-- 12 months of the book. If the source is ever refreshed, the windows move with
-- it and the KPI values change accordingly.
window_bounds as (

    select
        max(received_date) as anchor_date,

        max(received_date) - interval 12 month as last_window_start,

        max(received_date) - interval 24 month as prior_window_start

    from loans

    where received_date is not null

),


recent_windows as (

    select

        sum(
            case
                when loans.received_date > window_bounds.last_window_start then 1
                else 0
            end
        ) as funded_loan_count_last_12_months,

        avg(
            case
                when loans.received_date > window_bounds.last_window_start
                    then cast(loans.is_loss as integer)
            end
        ) as loss_rate_last_12_months,

        sum(
            case
                when loans.received_date <= window_bounds.last_window_start
                    and loans.received_date > window_bounds.prior_window_start then 1
                else 0
            end
        ) as funded_loan_count_prior_12_months,

        avg(
            case
                when loans.received_date <= window_bounds.last_window_start
                    and loans.received_date > window_bounds.prior_window_start
                    then cast(loans.is_loss as integer)
            end
        ) as loss_rate_prior_12_months

    from loans

    cross join window_bounds

),


-- Everything except the identifier and the outcome columns, so two rows match
-- only when every predictor value matches. Grouping on the row struct itself
-- avoids hashing a text rendering of 99 doubles, which would be sensitive to
-- how floats happen to be formatted.
feature_vectors as (

    select * exclude (
        loan_id,
        received_date,
        is_loss,
        loss_amount
    )

    from {{ ref('int_loans_joined') }}

),


feature_vector_groups as (

    select
        feature_vectors as feature_vector,

        count(*) as loans_sharing_vector

    from feature_vectors

    group by feature_vector

),


duplicate_records as (

    select

        count(*) filter (
            where loans_sharing_vector > 1
        ) as duplicate_feature_vector_groups,

        sum(loans_sharing_vector) filter (
            where loans_sharing_vector > 1
        ) as duplicate_feature_vector_loan_count,

        sum(loans_sharing_vector) filter (
            where loans_sharing_vector > 1
        ) * 1.0
            / sum(loans_sharing_vector)
            as duplicate_feature_vector_rate,

        count(*) as distinct_feature_vector_count

    from feature_vector_groups

),


-- Three single-row CTEs, so the cross join produces exactly one row holding
-- every KPI as a column. The loop below turns that row into the long shape.
all_metrics as (

    select
        portfolio_metrics.*,

        recent_windows.*,

        recent_windows.loss_rate_last_12_months
            - recent_windows.loss_rate_prior_12_months
            as loss_rate_12_month_change,

        duplicate_records.*

    from portfolio_metrics

    cross join recent_windows

    cross join duplicate_records

),


kpi_long as (

    {% for kpi in kpis %}

        select
            '{{ kpi.group }}' as kpi_group,

            '{{ kpi.name }}' as kpi_name,

            '{{ kpi.unit }}' as kpi_unit,

            {{ loop.index }} as kpi_display_order,

            {% if kpi.headline %}true{% else %}false{% endif %} as is_headline,

            {% if kpi.unit == 'date' %}
                cast(null as double) as kpi_value,
                strftime({{ kpi.name }}, '%Y-%m-%d') as kpi_value_text
            {% else %}
                cast({{ kpi.name }} as double) as kpi_value,
                cast(null as varchar) as kpi_value_text
            {% endif %}

        from all_metrics

        {% if not loop.last %}
            union all
        {% endif %}

    {% endfor %}

)

select *
from kpi_long
order by kpi_display_order
