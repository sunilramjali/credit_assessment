{% set sentinels = sentinel_columns() %}

{#
    Model-ready feature table for the loss_amount severity regression.

    Deliberately a separate model from mart_ml_training_set, not a variation of
    it. In the classifier, loss_amount is a leak and is dropped. Here it is the
    target. Two different problems need two different tables, and the friction
    of building a second one is what stops a feature from quietly becoming an
    answer.

    Population is loss_amount > 0. This models severity -- the size of the loss
    given that a loss occurred -- which pairs with the classifier's probability
    of a loss to give expected loss per funded loan. Modelling loss_amount over
    all 10,000 loans instead would put 75.67% zeros in the target and turn the
    exercise into a zero-inflated problem that linear regression handles badly.

    Fixed rules applied here, matching the classifier mart:
      1. split assigned by date, never at random
      2. sentinel codes become NULL, with an indicator preserving the absence

    Rare-category grouping is NOT done here, unlike in the classifier mart. It
    is a fitted step -- it learns which categories are common from the training
    rows -- so it belongs inside the modelling pipeline, where the regression
    notebook implements it as a transformer fitted on train only.
#}

with positive_loss_loans as (

    select *

    from {{ ref('int_loans_joined') }}

    where loss_amount > 0

),


labelled as (

    select
        *,

        case
            when received_date < date '{{ var("train_cutoff_date", "2024-10-01") }}'
                then 'train'
            else 'test'
        end as split

    from positive_loss_loans

),


final as (

    select
        labelled.loan_id,

        labelled.split,

        -- Target.
        labelled.loss_amount,

        -- Retained for error analysis by vintage, never as a feature.
        labelled.received_date,

        -- Retained for analysis only. On this population is_loss is true for
        -- 2,099 of 2,232 rows; the 133 exceptions are the known label
        -- conflicts. It is the classifier's target and must not be a feature
        -- here.
        labelled.is_loss,

        labelled.feat_001,
        labelled.feat_003,
        labelled.feat_004,
        labelled.feat_015,
        labelled.feat_041,

        {% for s in sentinels %}
        case
            when labelled.{{ s.column }} >= {{ s.threshold }} then null
            else labelled.{{ s.column }}
        end as {{ s.column }},

        case
            when labelled.{{ s.column }} >= {{ s.threshold }} then 1
            else 0
        end as is_unobserved_{{ s.column }},

        {% endfor %}

        labelled.* exclude (
            loan_id,
            received_date,
            is_loss,
            loss_amount,
            split,
            feat_001,
            feat_003,
            feat_004,
            feat_015,
            feat_041
            {% for s in sentinels %},
            {{ s.column }}
            {% endfor %}
        )

    from labelled

)

select *
from final
order by
    split desc,
    loan_id
