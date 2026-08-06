with source as (

    select *
    from {{ source('raw', 'features') }}

),

staged as (

    select
        cast(loan_id as varchar) as loan_id,

        cast(feat_001 as varchar) as feat_001,
        cast(feat_003 as varchar) as feat_003,
        cast(feat_004 as boolean) as feat_004,
        cast(feat_015 as boolean) as feat_015,
        cast(feat_041 as varchar) as feat_041,

        cast(
            columns(
                * exclude (
                    loan_id,
                    feat_001,
                    feat_003,
                    feat_004,
                    feat_015,
                    feat_041
                )
            )
            as double
        )

    from source

)

select *
from staged