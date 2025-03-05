import json
import yaml
import os
import csv
from snakemake.utils import min_version
min_version("6.0")

# Load configuration
configfile: "resources/config/params.yaml"

# Function to parse metasheet and extract sample information
def get_samples_from_metasheet():
    samples = {}
    try:
        with open(config["metasheet_path"], "r") as f:
            reader = csv.DictReader(f)
            for row in reader:
                sample_name = row["sample"]
                samples[sample_name] = {
                    "R1": row["R1"],
                    "R2": row["R2"],
                    "srr": os.path.basename(row["R1"]).replace("_R1.fastq.gz", "")  # Get SRR ID from filename
                }
                print(f"Loaded sample: {sample_name}, SRR: {samples[sample_name]['srr']}")
    except FileNotFoundError:
        print(f"Error: Metasheet not found at {config['metasheet_path']}")
        raise
    except KeyError as e:
        print(f"Error: Missing required column in metasheet: {e}")
        raise
    return samples

# Store samples from metasheet in a dictionary
SAMPLES = get_samples_from_metasheet()

# Create the directory structure
for dir in ["logs/trimming", "Analysis/Trimmed", "Analysis/QC/Trimming/Reports"]:
    os.makedirs(dir, exist_ok=True)

# Load the trimming parameters from the JSON file
def load_trimming_params():
    params_file = "Analysis/QC/Trimming/trimming_params.json"
    if not os.path.exists(params_file):
        print(f"WARNING: No trimming parameters file found at {params_file}.")
        print("Will use default parameters for all samples.")
        return {}
    
    try:
        with open(params_file, "r") as f:
            return json.load(f)
    except Exception as e:
        print(f"ERROR: Could not parse trimming parameters: {str(e)}")
        return {}

# Store trimming parameters
TRIMMING_PARAMS = load_trimming_params()

# Helper function to get trimming parameters for a specific sample
def get_sample_params(sample_name, srr_id):
    """Get trimming parameters for a sample, trying multiple possible keys."""
    # Try different variations of sample identifier
    possible_keys = [
        sample_name,              # Try the sample name as-is
        srr_id,                   # Try just the SRR ID
        f"{sample_name}_{srr_id}",  # Try combined format
        srr_id.split("_")[0] if "_" in srr_id else srr_id,  # Try first part of SRR
    ]
    
    # Try all possible keys
    for key in possible_keys:
        if key in TRIMMING_PARAMS:
            print(f"Found parameters for key: {key}")
            return TRIMMING_PARAMS[key]
    
    # If no exact match, try substring matching
    for key in TRIMMING_PARAMS:
        for id_key in possible_keys:
            if id_key in key:
                print(f"Found parameters via substring match: {id_key} in {key}")
                return TRIMMING_PARAMS[key]
    
    # No match found, use default parameters
    print(f"No parameters found for {sample_name}/{srr_id}. Using defaults.")
    return {
        "leading_quality": config.get("leading_quality", 3),
        "trailing_quality": config.get("trailing_quality", 3),
        "sliding_window": config.get("sliding_window", "4:15"),
        "min_length": config.get("min_length", 36),
        "customized": False
    }

# Rule to run trimming for all samples
rule trim_all:
    input:
        expand("Analysis/Trimmed/{sample}/{srr}_R1_trimmed.fastq.gz",
               sample=SAMPLES.keys(), 
               srr=[SAMPLES[s]["srr"] for s in SAMPLES.keys()]),
        expand("Analysis/Trimmed/{sample}/{srr}_R2_trimmed.fastq.gz",
               sample=SAMPLES.keys(), 
               srr=[SAMPLES[s]["srr"] for s in SAMPLES.keys()]),
        "Analysis/QC/Trimming/MultiQC/multiqc_report.html"

# Rule to run fastp with sample-specific parameters
rule fastp:
    input:
        r1=lambda wildcards: SAMPLES[wildcards.sample]["R1"],
        r2=lambda wildcards: SAMPLES[wildcards.sample]["R2"]
    output:
        r1="Analysis/Trimmed/{sample}/{srr}_R1_trimmed.fastq.gz",
        r2="Analysis/Trimmed/{sample}/{srr}_R2_trimmed.fastq.gz",
        html="Analysis/QC/Trimming/Reports/{sample}_{srr}_fastp.html",
        json="Analysis/QC/Trimming/Reports/{sample}_{srr}_fastp.json"
    log:
        "logs/trimming/{sample}_{srr}.log"
    params:
        sample_params=lambda wildcards: get_sample_params(wildcards.sample, wildcards.srr)
    threads: config.get("trimming_threads", 4)
    resources:
        mem_mb=config.get("trimming_memory", 8000),
        time=config.get("trimming_time", "02:00:00")
    shell:
        """
        # Create output directories
        mkdir -p $(dirname {output.r1})
        mkdir -p $(dirname {output.html})
        
        # Debug information
        echo "Processing sample: {wildcards.sample}, SRR: {wildcards.srr}" >> {log}
        echo "Input R1: {input.r1}" >> {log}
        echo "Input R2: {input.r2}" >> {log}
        echo "Output R1: {output.r1}" >> {log}
        echo "Output R2: {output.r2}" >> {log}
        
        # Extract parameters
        PARAMS='{params.sample_params}'
        echo "Parameters: $PARAMS" >> {log}
        
        # Extract quality settings
        LEADING_QUALITY=$(echo '$PARAMS' | python -c "import sys, json; print(json.loads(sys.stdin.read()).get('leading_quality', 3))")
        TRAILING_QUALITY=$(echo '$PARAMS' | python -c "import sys, json; print(json.loads(sys.stdin.read()).get('trailing_quality', 3))")
        MIN_LENGTH=$(echo '$PARAMS' | python -c "import sys, json; print(json.loads(sys.stdin.read()).get('min_length', 36))")
        
        # Parse sliding window into components
        SLIDING_WINDOW=$(echo '$PARAMS' | python -c "import sys, json; print(json.loads(sys.stdin.read()).get('sliding_window', '4:15'))")
        WINDOW_SIZE=$(echo $SLIDING_WINDOW | cut -d: -f1)
        WINDOW_QUALITY=$(echo $SLIDING_WINDOW | cut -d: -f2)
        
        echo "Extracted parameters:" >> {log}
        echo "  Leading quality: $LEADING_QUALITY" >> {log}
        echo "  Trailing quality: $TRAILING_QUALITY" >> {log}
        echo "  Min length: $MIN_LENGTH" >> {log}
        echo "  Window size: $WINDOW_SIZE" >> {log}
        echo "  Window quality: $WINDOW_QUALITY" >> {log}
        
        # Build custom options
        CUSTOM_OPTS=""
        
        # Check for specific flags
        DEDUP=$(echo '$PARAMS' | python -c "import sys, json; print('true' if json.loads(sys.stdin.read()).get('deduplication', False) else 'false')")
        if [ "$DEDUP" = "true" ]; then
            CUSTOM_OPTS="$CUSTOM_OPTS --dedup"
            echo "  Using deduplication" >> {log}
        fi
        
        TRIM_POLY_G=$(echo '$PARAMS' | python -c "import sys, json; print('true' if json.loads(sys.stdin.read()).get('trim_poly_g', False) else 'false')")
        if [ "$TRIM_POLY_G" = "true" ]; then
            CUSTOM_OPTS="$CUSTOM_OPTS --trim_poly_g"
            echo "  Using poly-G trimming" >> {log}
        fi
        
        LOW_COMPLEXITY=$(echo '$PARAMS' | python -c "import sys, json; print('true' if json.loads(sys.stdin.read()).get('low_complexity_filter', False) else 'false')")
        if [ "$LOW_COMPLEXITY" = "true" ]; then
            CUSTOM_OPTS="$CUSTOM_OPTS --low_complexity_filter"
            echo "  Using low complexity filter" >> {log}
        fi
        
        # Run fastp with auto-adapter detection and determined parameters
        echo "Running fastp..." >> {log}
        fastp \
            --in1 {input.r1} \
            --in2 {input.r2} \
            --out1 {output.r1} \
            --out2 {output.r2} \
            --html {output.html} \
            --json {output.json} \
            --thread {threads} \
            --qualified_quality_phred $TRAILING_QUALITY \
            --unqualified_percent_limit 40 \
            --cut_front \
            --cut_front_window_size $WINDOW_SIZE \
            --cut_front_mean_quality $WINDOW_QUALITY \
            --cut_tail \
            --cut_tail_window_size $WINDOW_SIZE \
            --cut_tail_mean_quality $WINDOW_QUALITY \
            --length_required $MIN_LENGTH \
            --detect_adapter_for_pe \
            $CUSTOM_OPTS \
            >> {log} 2>&1
        
        # Verify outputs
        if [ ! -f "{output.r1}" ] || [ ! -f "{output.r2}" ]; then
            echo "ERROR: Output files were not created properly." >> {log}
            echo "Command failed, check log for details." >> {log}
            exit 1
        fi
        
        echo "Trimming completed successfully" >> {log}
        
        # Print basic stats
        echo "Output file sizes:" >> {log}
        ls -lh {output.r1} {output.r2} >> {log}
        """

# Rule to run MultiQC on fastp reports
rule multiqc_fastp:
    input:
        fastp_reports=expand("Analysis/QC/Trimming/Reports/{sample}_{srr}_fastp.json",
                           sample=SAMPLES.keys(), 
                           srr=[SAMPLES[s]["srr"] for s in SAMPLES.keys()])
    output:
        html="Analysis/QC/Trimming/MultiQC/multiqc_report.html",
        data_dir=directory("Analysis/QC/Trimming/MultiQC/multiqc_data")
    log:
        "logs/trimming/multiqc_fastp.log"
    shell:
        """
        # Create output directory
        mkdir -p $(dirname {output.html})
        
        # Run MultiQC on fastp reports
        echo "Running MultiQC on fastp reports..." >> {log}
        
        # List input files for debugging
        echo "Input files:" >> {log}
        for f in {input.fastp_reports}; do
            echo "  $f" >> {log}
            # Check file size
            ls -lh $f >> {log}
        done
        
        multiqc \
            --force \
            --outdir $(dirname {output.html}) \
            --filename $(basename {output.html}) \
            Analysis/QC/Trimming/Reports/ \
            > {log} 2>&1
            
        # Verify output
        if [ ! -f "{output.html}" ]; then
            echo "ERROR: MultiQC report was not created" >> {log}
            exit 1
        fi
        
        echo "MultiQC completed successfully" >> {log}
        """