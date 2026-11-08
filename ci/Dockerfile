FROM artifactory.rafael.co.il/rtsis-docker-local-ww/yocto-scarthgap:v1.4.0@sha256:cdbc91647527de4327ece518e4bbf3f2c5a0e0d4b1604bf420ed6557afb5d3c2

RUN python3 -m pip install --no-cache-dir --upgrade "pip==26.3" \
    && python3 -m pip install --no-cache-dir "kas==4.8.2" \
    && kas --version
