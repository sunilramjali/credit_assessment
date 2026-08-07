-- Every training loan must pre-date every test loan.
--
-- This is the assertion the whole modelling result rests on. If a single test
-- row leaked into the training period, the model would be scored partly on data
-- it had already seen, and nothing else in the pipeline would notice: accuracy
-- would simply improve.
--
-- It also guards the duplicate leak indirectly. Duplicate groups always share a
-- received_date, so as long as the split is a clean date boundary, no duplicate
-- group can span it.

with bounds as (

    select
        max(case when split = 'train' then received_date end) as last_train_date,
        min(case when split = 'test' then received_date end) as first_test_date

    from {{ ref('mart_ml_training_set') }}

)

select *

from bounds

where last_train_date >= first_test_date
