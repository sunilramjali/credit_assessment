{#
    Single definition of the portfolio KPI list.

    Both `mart_portfolio_kpis` (long, one row per KPI) and
    `mart_portfolio_kpis_wide` (one row, one column per KPI) loop over this
    list. Keeping it here is what stops the two shapes from drifting apart:
    a KPI added below appears in both marts on the next build.

    `name` must match a column produced by the `all_metrics` CTE in
    `mart_portfolio_kpis`.
#}

{% macro kpi_definitions() %}

    {{ return([

        {'group': 'volume',       'name': 'funded_loan_count',                  'unit': 'count',       'headline': true},
        {'group': 'volume',       'name': 'first_origination_date',             'unit': 'date',        'headline': false},
        {'group': 'volume',       'name': 'last_origination_date',              'unit': 'date',        'headline': false},
        {'group': 'volume',       'name': 'origination_window_days',            'unit': 'count',       'headline': false},
        {'group': 'volume',       'name': 'distinct_origination_days',          'unit': 'count',       'headline': false},

        {'group': 'frequency',    'name': 'loss_loan_count',                    'unit': 'count',       'headline': false},
        {'group': 'frequency',    'name': 'non_loss_loan_count',                'unit': 'count',       'headline': false},
        {'group': 'frequency',    'name': 'portfolio_loss_rate',                'unit': 'rate',        'headline': true},
        {'group': 'frequency',    'name': 'funded_loan_count_last_12_months',   'unit': 'count',       'headline': false},
        {'group': 'frequency',    'name': 'loss_rate_last_12_months',           'unit': 'rate',        'headline': true},
        {'group': 'frequency',    'name': 'funded_loan_count_prior_12_months',  'unit': 'count',       'headline': false},
        {'group': 'frequency',    'name': 'loss_rate_prior_12_months',          'unit': 'rate',        'headline': false},
        {'group': 'frequency',    'name': 'loss_rate_12_month_change',          'unit': 'rate_change', 'headline': true},

        {'group': 'severity',     'name': 'total_recorded_loss_amount',         'unit': 'amount',      'headline': true},
        {'group': 'severity',     'name': 'total_positive_loss_amount',         'unit': 'amount',      'headline': false},
        {'group': 'severity',     'name': 'total_net_recovery_amount',          'unit': 'amount',      'headline': false},
        {'group': 'severity',     'name': 'average_loss_per_funded_loan',       'unit': 'amount',      'headline': true},
        {'group': 'severity',     'name': 'average_loss_severity',              'unit': 'amount',      'headline': true},
        {'group': 'severity',     'name': 'median_loss_severity',               'unit': 'amount',      'headline': false},
        {'group': 'severity',     'name': 'maximum_loss_amount',                'unit': 'amount',      'headline': false},

        {'group': 'data_quality', 'name': 'label_conflict_loan_count',          'unit': 'count',       'headline': false},
        {'group': 'data_quality', 'name': 'label_conflict_rate',                'unit': 'rate',        'headline': false},
        {'group': 'data_quality', 'name': 'net_recovery_loan_count',            'unit': 'count',       'headline': false},
        {'group': 'data_quality', 'name': 'missing_loss_amount_count',          'unit': 'count',       'headline': false},
        {'group': 'data_quality', 'name': 'missing_received_date_count',        'unit': 'count',       'headline': false},
        {'group': 'data_quality', 'name': 'duplicate_feature_vector_groups',    'unit': 'count',       'headline': false},
        {'group': 'data_quality', 'name': 'duplicate_feature_vector_loan_count','unit': 'count',       'headline': false},
        {'group': 'data_quality', 'name': 'duplicate_feature_vector_rate',      'unit': 'rate',        'headline': true},
        {'group': 'data_quality', 'name': 'distinct_feature_vector_count',      'unit': 'count',       'headline': false}

    ]) }}

{% endmacro %}
