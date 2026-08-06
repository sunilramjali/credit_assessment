with source as (
    select * from {{ source('raw', 'loans')}}
)

select
    cast(loan_id as varchar) as loan_id,
    cast(received_date as date) as received_date,
    cast(is_loss as boolean) as is_loss,
    cast(loss_amount as decimal(12, 2)) as loss_amount

from source