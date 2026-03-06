# Runner image — used during the run phase.
# Runs the full FuzzingBrain CRS with DinD for internal fuzzer builds.
FROM fuzzing-brain-base

COPY --from=libcrs . /libCRS
RUN /libCRS/install.sh

ENTRYPOINT ["/opt/fuzzing-brain-oss-crs/run_fuzzingbrain.sh"]
