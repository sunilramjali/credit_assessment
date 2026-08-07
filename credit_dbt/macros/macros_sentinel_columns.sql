{#
    The 19 numeric feature columns that encode "no observation" as a large
    placeholder number instead of NULL.

    A column is listed only where the placeholder is a recognisable all-nines
    code (995-999, 9,995-9,999, 99,995-99,999, or 1,000,000,000) sitting far
    above the largest genuine value in the column. Two further columns were
    flagged by an automated gap search and rejected on inspection:
    feat_071_min and feat_057_min run continuously up to 18.6 million and 736
    million, so their apparent cliffs are ordinary long tails, not codes.

    `threshold` is the value at or above which a reading is a code, never a
    measurement. `share` records the proportion of rows on the code at the time
    of writing and is documentation only -- nothing reads it.
#}

{% macro sentinel_columns() %}

    {{ return([

        {'column': 'feat_066_min', 'threshold': 995,         'share': 0.870},
        {'column': 'feat_064_max', 'threshold': 99995,       'share': 0.764},
        {'column': 'feat_030_max', 'threshold': 999999000,   'share': 0.729},
        {'column': 'feat_050_min', 'threshold': 999999000,   'share': 0.725},
        {'column': 'feat_062_min', 'threshold': 999999000,   'share': 0.670},
        {'column': 'feat_070_min', 'threshold': 995,         'share': 0.463},
        {'column': 'feat_017_sum', 'threshold': 999999000,   'share': 0.357},
        {'column': 'feat_029_min', 'threshold': 995,         'share': 0.239},
        {'column': 'feat_052_min', 'threshold': 999999000,   'share': 0.238},
        {'column': 'feat_068_min', 'threshold': 995,         'share': 0.213},
        {'column': 'feat_007_min', 'threshold': 999999000,   'share': 0.200},
        {'column': 'feat_031_min', 'threshold': 995,         'share': 0.190},
        {'column': 'feat_026_min', 'threshold': 995,         'share': 0.159},
        {'column': 'feat_058_min', 'threshold': 9995,        'share': 0.159},
        {'column': 'feat_045_sum', 'threshold': 999999000,   'share': 0.137},
        {'column': 'feat_083_min', 'threshold': 995,         'share': 0.120},
        {'column': 'feat_061_max', 'threshold': 999999000,   'share': 0.069},
        {'column': 'feat_046_sum', 'threshold': 999999000,   'share': 0.068},
        {'column': 'feat_023_min', 'threshold': 999999000,   'share': 0.043}

    ]) }}

{% endmacro %}
