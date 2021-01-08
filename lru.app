{application,lru,[
    {description,"Least Recently Used Algorithm"},
    {vsn,"1.0.1"},
    {modules,[
        lru_app,lru_sup,lru,
        lru_protocol,lru_utils
    ]},
    {registered,[
        lru_sup,lru
    ]},
    {applications,[kernel,stdlib]},
    {included_applications,[ranch]},
    {mod,{lru_app,[]}},
    {start_phases,[]},
    {env,[]},
    {maintainers,["Vladimir Solenkov"]},
    {links,[{"Github","https://github.com/Algorithms-Lab/LRU.git"}]}
]}.
