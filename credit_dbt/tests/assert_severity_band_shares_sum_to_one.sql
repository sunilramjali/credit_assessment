-- Every loss-making loan must land in exactly one severity band, so both share
-- columns must sum to 1. This catches a gap or an overlap in the CASE
-- boundaries, which is easy to introduce by changing < to <= on one line and
-- produces no error anywhere else.

select
    sum(positive_loss_loan_share) as total_loan_share,
    sum(positive_loss_amount_share) as total_amount_share

from {{ ref('mart_loss_severity_bands') }}

having abs(sum(positive_loss_loan_share) - 1) > 0.000001
    or abs(sum(positive_loss_amount_share) - 1) > 0.000001
