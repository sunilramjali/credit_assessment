{% set sentinels = sentinel_columns() %}

{#
    Model-ready feature table for the is_loss classifier.

    This model performs only transformations that are FIXED RULES -- steps that
    need no knowledge of the data to apply, and so cannot leak test information
    into training. Anything that must be FITTED (imputation, scaling, encoding)
    is deliberately left to the notebook, where it is fitted on the training
    rows alone.

    Fixed rules applied here:
      1. loss_amount is dropped entirely (leakage guard)
      2. split is assigned by date, never at random
      3. rare feat_001 levels collapse to OTHER, using TRAIN counts only
      4. sentinel codes become NULL, with an indicator column preserving the
         fact that the value was absent
#}

with base as (

    select * from {{ ref('int_loans_joined') }}

),


-- Time-based, not random. 54.3% of rows are duplicates and every duplicate
-- group shares a date, so a random split would place identical records on both
-- sides and the test score would measure memorisation. Zero of the 2,435
-- duplicate groups straddle this cutoff.
labelled as (

    select
        *,

        case
            when received_date < date '{{ var("train_cutoff_date", "2024-10-01") }}'
                then 'train'
            else 'test'
        end as split

    from base

),


-- Rare-level counts come from the TRAIN rows only. Deciding which categories
-- are "common" using the whole dataset would let the test set influence the
-- encoding, which is leakage even though no target value is touched.
train_segment_counts as (

    select
        feat_001,
        count(*) as train_loan_count

    from labelled

    where split = 'train'

    group by feat_001

),


final as (

    select
        labelled.loan_id,

        labelled.split,

        -- Target. Kept as boolean; the notebook casts it.
        labelled.is_loss,

        -- Retained for cohort analysis of errors, never as a feature.
        labelled.received_date,

        case
            when coalesce(train_segment_counts.train_loan_count, 0) >= 100
                then labelled.feat_001
            else 'OTHER'
        end as feat_001_grouped,

        labelled.feat_003,
        labelled.feat_004,
        labelled.feat_015,
        labelled.feat_041,

        {% for s in sentinels %}
        -- {{ s.column }}: {{ (s.share * 100) | round(1) }}% of rows carry the code
        case
            when labelled.{{ s.column }} >= {{ s.threshold }} then null
            else labelled.{{ s.column }}
        end as {{ s.column }},

        case
            when labelled.{{ s.column }} >= {{ s.threshold }} then 1
            else 0
        end as is_unobserved_{{ s.column }},

        {% endfor %}

        -- Every remaining feature, untouched. loss_amount is excluded here:
        -- it is near-deterministic with the target and would leak the answer.
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

    left join train_segment_counts
        on labelled.feat_001 = train_segment_counts.feat_001

)

select *
from final
order by
    split desc,
    loan_id
