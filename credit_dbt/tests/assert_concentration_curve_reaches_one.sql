-- The concentration curve must end at exactly (1, 1): the last-ranked loan
-- completes both the loan population and the loss total.
--
-- This is the cheapest possible check that the window functions are ordered
-- and framed correctly. A wrong frame -- for example the default RANGE frame
-- instead of ROWS, which lumps tied values together -- still produces a curve
-- that rises left to right and looks entirely convincing on a chart.

select
    max(cumulative_positive_loss_loan_share) as final_loan_share,
    max(cumulative_positive_loss_share) as final_loss_share

from {{ ref('mart_loss_concentration') }}

having abs(max(cumulative_positive_loss_loan_share) - 1) > 0.000001
    or abs(max(cumulative_positive_loss_share) - 1) > 0.000001
