{% set categorical_features = categorical_features() %}


with base as (

    select
        loan_id,
        year(received_date) as origination_year,
        is_loss,
        loss_amount,

        {% for feature in categorical_features %}
            {{ feature }}{% if not loop.last %},{% endif %}
        {% endfor %}

    from {{ ref('int_loans_joined') }}

),


categorical_long as (

    {% for feature in categorical_features %}

        select
            loan_id,
            origination_year,

            '{{ feature }}' as feature_name,

            coalesce(
                cast({{ feature }} as varchar),
                '__NULL__'
            ) as feature_value,

            is_loss,
            loss_amount

        from base

        {% if not loop.last %}
            union all
        {% endif %}

    {% endfor %}

),


portfolio_totals as (

    select
        feature_name,
        origination_year,
        count(*) as total_feature_loans

    from categorical_long

    group by
        feature_name,
        origination_year

),


category_metrics as (

    select
        feature_name,
        feature_value,
        origination_year,

        count(*) as loan_count,

        sum(
            case
                when is_loss = 1 then 1
                else 0
            end
        ) as loss_count,

        avg(
            case
                when is_loss = 1 then 1.0
                else 0.0
            end
        ) as observed_loss_rate,

        avg(
            case
                when is_loss = 1 then loss_amount
                else null
            end
        ) as average_loss_severity,

        sum(
            case
                when is_loss = 1 then loss_amount
                else 0
            end
        ) as total_observed_loss

    from categorical_long

    group by
        feature_name,
        feature_value,
        origination_year

),


final as (

    select

        {{ dbt_utils.generate_surrogate_key([
            'c.feature_name',
            'c.feature_value',
            'c.origination_year'
        ]) }} as feature_category_key,

        c.feature_name,

        c.feature_value,

        c.origination_year,

        c.loan_count,

        c.loan_count * 1.0
            / p.total_feature_loans
            as portfolio_share,

        c.loss_count,

        c.observed_loss_rate,

        c.average_loss_severity,

        c.total_observed_loss,

        c.total_observed_loss * 1.0
            / c.loan_count
            as observed_loss_per_loan,

        case
            when c.loan_count >= 50 then true
            else false
        end as sufficient_sample_flag

    from category_metrics c

    left join portfolio_totals p
        on c.feature_name = p.feature_name
        and c.origination_year = p.origination_year

)

select *
from final