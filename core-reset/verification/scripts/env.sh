# Tools: from OSS_CAD_SUITE (bin/ of an oss-cad-suite), else from EDA_PREFIX (default /opt/eda, where this
# work built Verilator 5.050, Yosys 0.70 and SymbiYosys 0.70 from source), then PATH. Yices for yosys-smtbmc
# may come from a Python venv (yices-solver): EDA_EXTRA_PATH, default /opt/fv/bin.
[ -n "$OSS_CAD_SUITE" ] && export PATH=$OSS_CAD_SUITE/bin:$PATH
EDA_PREFIX=${EDA_PREFIX:-/opt/eda}
[ -z "$OSS_CAD_SUITE" ] && [ -d "$EDA_PREFIX/bin" ] && export PATH=$EDA_PREFIX/bin:$PATH
EDA_EXTRA_PATH=${EDA_EXTRA_PATH:-/opt/fv/bin}
[ -d "$EDA_EXTRA_PATH" ] && export PATH=$PATH:$EDA_EXTRA_PATH
true
