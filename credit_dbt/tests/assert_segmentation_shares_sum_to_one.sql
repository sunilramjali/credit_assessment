-- Both share columns must sum to 1 WITHIN EACH FEATURE.
--
-- The grouping matters. Every feature partitions the same 10,000 loans, so the
-- table holds five copies of the book and the shares sum to 5 overall. An
-- ungrouped version of this test would fail on correct data, and -- worse -- a
-- version that divided by the long table's 50,000 rows would pass while every
-- share was five times too small.
--
-- This is the same mistake the categorical mart makes with its portfolio_share
-- column, which sums to 8 because its denominator is one feature-year rather
-- than the book.
--
-- Tolerance is for floating point only, not for genuine drift.

select
    feature_name,
    sum(portfolio_loan_share) as total_loan_share,
    sum(portfolio_positive_loss_share) as total_positive_loss_share

from {{ ref('mart_risk_segmentation') }}

group by feature_name

having abs(sum(portfolio_loan_share) - 1) > 0.000001
    or abs(sum(portfolio_positive_loss_share) - 1) > 0.000001
