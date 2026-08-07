{% set categorical_features = categorical_features() %}


with base as (

    select
        loan_id,
        is_loss,
        loss_amount,

        {% for feature in categorical_features %}
            {{ feature }}{% if not loop.last %},{% endif %}
        {% endfor %}

    from {{ ref('int_loans_joined') }}

),


-- One row per loan per feature, so all five features can be segmented by the
-- same aggregation. Missing values become their own category rather than
-- disappearing, because whether a value is absent may itself separate risk.
segments_long as (

    {% for feature in categorical_features %}

        select
            loan_id,

            '{{ feature }}' as feature_name,

            coalesce(
                cast({{ feature }} as varchar),
                '__NULL__'
            ) as segment,

            is_loss,
            loss_amount

        from base

        {% if not loop.last %}
            union all
        {% endif %}

    {% endfor %}

),


-- Denominators come from `base`, which is one row per loan, not from
-- segments_long, which repeats every loan once per feature. Taking totals from
-- the long table would divide by 50,000 and quietly shrink every share.
portfolio_totals as (

    select
        count(*) as portfolio_loan_count,

        avg(cast(is_loss as integer)) as portfolio_loss_rate,

        sum(
            case
                when loss_amount > 0 then loss_amount
                else 0
            end
        ) as portfolio_positive_loss_amount

    from base

),


segment_metrics as (

    select
        feature_name,

        segment,

        count(*) as funded_loan_count,

        sum(cast(is_loss as integer)) as loss_loan_count,

        -- The denominator behind average_positive_loss_severity. Published so
        -- that a report grouping segments together can recompute the average
        -- correctly, instead of averaging segment-level averages.
        sum(
            case
                when loss_amount > 0 then 1
                else 0
            end
        ) as positive_loss_loan_count,

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
                when loss_amount > 0 then loss_amount
            end
        ) as average_positive_loss_severity,

        median(
            case
                when loss_amount > 0 then loss_amount
            end
        ) as median_positive_loss_severity,

        max(
            case
                when loss_amount > 0 then loss_amount
            end
        ) as maximum_positive_loss_amount

    from segments_long

    group by
        feature_name,
        segment

),


final as (

    select
        segment_metrics.feature_name,

        segment_metrics.segment,

        segment_metrics.funded_loan_count,

        segment_metrics.loss_loan_count,

        segment_metrics.positive_loss_loan_count,

        segment_metrics.observed_loss_rate,

        -- Share of the whole book. Each feature partitions all 10,000 loans, so
        -- this sums to 1 within a feature and to 5 across the table. Always
        -- filter to one feature before reading a share.
        segment_metrics.funded_loan_count * 1.0
            / portfolio_totals.portfolio_loan_count
            as portfolio_loan_share,

        segment_metrics.total_recorded_loss_amount,

        segment_metrics.total_positive_loss_amount,

        segment_metrics.total_positive_loss_amount
            / nullif(portfolio_totals.portfolio_positive_loss_amount, 0)
            as portfolio_positive_loss_share,

        segment_metrics.average_loss_per_funded_loan,

        segment_metrics.average_positive_loss_severity,

        segment_metrics.median_positive_loss_severity,

        segment_metrics.maximum_positive_loss_amount,

        -- The benchmark is the whole book and does not change by feature: every
        -- feature partitions the same 10,000 loans.
        portfolio_totals.portfolio_loss_rate,

        -- Percentage points, not percent change. A segment at 30% against a
        -- portfolio at 22% gives 8.0, never 36.4.
        (
            segment_metrics.observed_loss_rate
            - portfolio_totals.portfolio_loss_rate
        ) * 100 as loss_rate_difference_pp,

        case
            when segment_metrics.funded_loan_count >= 100 then true
            else false
        end as is_material_segment,

        -- Transparent rule, not a model. The sample gate comes first so a
        -- three-loan segment can never be labelled High risk.
        case
            when segment_metrics.funded_loan_count < 100
                then 'Insufficient sample'
            when (
                segment_metrics.observed_loss_rate
                - portfolio_totals.portfolio_loss_rate
            ) * 100 >= 5 then 'High risk'
            when (
                segment_metrics.observed_loss_rate
                - portfolio_totals.portfolio_loss_rate
            ) * 100 <= -5 then 'Low risk'
            else 'Portfolio-like'
        end as risk_band

    from segment_metrics

    cross join portfolio_totals

)

select *
from final
order by
    feature_name,
    observed_loss_rate desc,
    funded_loan_count desc
