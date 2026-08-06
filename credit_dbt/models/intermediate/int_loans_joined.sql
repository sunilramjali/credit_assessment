with loans as (

    select *
    from {{ ref('stg_loans') }}

),

loan_features as (

    select *
    from {{ ref('stg_loan_features') }}

),

joined as (

    select
        loans.loan_id,
        loans.received_date,
        loans.is_loss,
        loans.loss_amount,
        loan_features.* exclude (loan_id)

    from loans

    left join loan_features
        on loans.loan_id = loan_features.loan_id

)

select *
from joined