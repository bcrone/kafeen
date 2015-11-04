# A library of available pipeline commands
#
# @author Sean Ephraim

require 'logger'
require 'open3'
require 'uri'

class Command
  # Result file paths
  attr_reader :genes2regions_result
  attr_reader :regions2variants_result
  attr_reader :addgenes_result
  attr_reader :addpredictions_result
  attr_reader :finalize_pathogenicity_result

  ##
  # Initialize
  ##
  def initialize(log_level: 'INFO', log_out: STDOUT)
    # Set custom VCF tags that will be added
    @gerp_pred_tag = "GERP_PRED"
    @phylop20way_mammalian_pred_tag = "PHYLOP20WAY_MAMMALIAN_PRED"
    @num_path_preds_tag = "NUM_PATH_PREDS"
    @total_num_preds_tag = "TOTAL_NUM_PREDS"
    @final_pred_tag = "FINAL_PRED"
    @final_pathogenicity_tag = "FINAL_PATHOGENICITY"
    @final_diseases_tag = "FINAL_DISEASE"
    @final_pmids_tag = "FINAL_PMIDS"
    @final_comments_tag = "FINAL_COMMENTS"
    @final_pathogenicity_source_tag = "FINAL_PATHOGENICITY_SOURCE"
    @final_pathogenicity_reason_tag = "FINAL_PATHOGENICITY_REASON"
    @clinvar_hgmd_conflict_tag = "CLINVAR_HGMD_CONFLICTED"

    # Set logger
    @@log = Logger.new(log_out)
    if log_level == 'UNKNOWN'
      @@log.level = Logger::UNKNOWN
    elsif log_level == 'FATAL'
      @@log.level = Logger::FATAL
    elsif log_level == 'ERROR'
      @@log.level = Logger::ERROR
    elsif log_level == 'WARN'
      @@log.level = Logger::WARN
    elsif log_level == 'DEBUG'
      @@log.level = Logger::DEBUG
    else
      @@log.level = Logger::INFO
    end
  end

  ##
  # Genes to Regions
  #
  # Get genomic regions for each HGNC gene symbol
  ##
  def genes2regions(genes_file:, ref_file:, out_file_prefix:)
    # Gene region reference file
    # Reference columns:
    #   chr, start, stop, gene_symbol
    f_regions = File.open(ref_file, 'r')

    # Set output file
    @genes2regions_result = "#{out_file_prefix}.gene_regions.bed"
    f_out = File.open(@genes2regions_result, 'w')
    
    File.open(genes_file, 'r').each_line do |gene|
      gene.chomp!
    
      # Get gene region
      result = f_regions.grep(/([^a-zA-Z0-9-]|^)#{gene}([^a-zA-Z0-9-]|$)/)
    
      # Print result
      if !result.empty?
        f_out.puts result
      end
    
      f_regions.rewind # reset file pointer
    end
    f_regions.close
    f_out.close
    @@log.info("Gene regions written to #{@genes2regions_result}")
  end

  ##
  # Regions to Variants
  #
  # Get a list of all variants within specified regions
  ##
  def regions2variants(bed_file:, vcf_files:, out_file_prefix:, keep_tmp_files: false)
    tmp_vcfs = {}
    File.open(bed_file).each do |region|
      chr,pos_start,pos_end,gene = region.chomp.split("\t")
      chr.sub!('chr', '')

      # Query all VCF files for variants
      vcf_files.each do |key, vcf|
        next if key == 'dbnsfp' # DO NOT MERGE dbNSFP - ONLY ANNOTATE WITH IT
        tmp_source_vcf = "#{out_file_prefix}.#{vcf['source']}.tmp.vcf.gz"
        if vcf['fields'].nil?
          # Remove all INFO tags
          fields = 'INFO'
        elsif vcf['fields'] == '*'
          # Keep all INFO tags
          fields = '*'
        else
          # Keep only the following INFO tags (indicated by ^)
          fields = "^" + vcf['fields'].map { |f| "INFO/#{f}" }.join(',')
        end

        # Query...
        @@log.info("Querying #{vcf['source']}...")
        if fields != '*'
          stdout, stderr = Open3.capture3(
            "bcftools annotate \
               --remove '#{fields}' \
               --regions-file '#{bed_file}' \
               --exclude 'TYPE=\"other\"' \
               #{vcf['filename']} \
             | bcftools norm \
                 --multiallelics '-' \
                 --output-type z \
                 --output #{tmp_source_vcf}"
          )
          stderr = stderr.sub(/^Lines total\/modified\/skipped.*/, '').strip # remove unnecessary "error"
          if !stderr.empty?
            @@log.warn("bcftools returned an error for #{vcf['source']}. Trying another query method...")
          end
        end

        # Did bcftools return an error?
        # Try again and don't remove any INFO tags this time
        if fields == '*' || !stderr.empty?
          stdout, stderr = Open3.capture3(
            "bcftools view \
               --regions-file '#{bed_file}' \
               --exclude 'TYPE=\"other\"' \
               #{vcf['filename']} \
             | bcftools norm \
                 --multiallelics '-' \
                 --output-type z \
                 --output #{tmp_source_vcf}"
          )
          stderr = stderr.sub(/^Lines total\/modified\/skipped.*/, '').strip # remove unnecessary "error"
        end

        # Index the results file...
        if !stderr.empty?
          # ERROR
          @@log.error("bcftools was not able to query #{vcf['source']}. Please check that file name and INFO tags are set correctly in your config file.")
        else
          # SUCCESS -- create index file
          @@log.info("Successfully queried #{vcf['source']}")
          @@log.info("Creating index file for #{vcf['source']}...")
          `bcftools index --force --tbi #{tmp_source_vcf}`
          @@log.info("Done creating index file")

          # Store tmp file name (filename) and the original VCF that the data came from (parent)
          tmp_vcfs[key] = {'filename' => tmp_source_vcf, 'parent' => vcf['filename']}
        end
      end
    end

    # Construct list of VCFs to merge
    files_to_merge = []
    tmp_vcfs.each do |key, tmp_vcf|
      next if key == 'dbnsfp' # DO NOT MERGE dbNSFP - ONLY ANNOTATE WITH IT
      files_to_merge << tmp_vcf['filename']
    end
    files_to_merge << tmp_vcfs['dbsnp']['filename']

    # Merge VCFs...
    @regions2variants_result = "#{out_file_prefix}.vcf.gz"
    @@log.info("Merging results...")
    `bcftools merge \
       --merge none \
       --output #{@regions2variants_result} \
       --output-type z \
       #{files_to_merge.join(' ')}`
    @@log.info("Done merging results")

    @@log.info("Creating index file for #{@regions2variants_result}...")
    `bcftools index --force --tbi #{@regions2variants_result}`
    @@log.info("Done creating index file")

    # Remove tmp files
    if !keep_tmp_files
      @@log.info("Removing temp files...")
      tmp_vcfs.each do |key, tmp_vcf|
        File.unlink(tmp_vcf['filename']) if File.exist?(tmp_vcf['filename'])
        File.unlink("#{tmp_vcf['filename']}.tbi") if File.exist?("#{tmp_vcf['filename']}.tbi")
      end
      @@log.info("Done removing temp files")
    end
  end

  ##
  # Take genes from BED file and add to VCF file
  ##
  def addgenes(bed_file:, vcf_file:, out_file_prefix:)
    # Prepare header file
    header_file = "#{out_file_prefix}.header.tmp.txt"
    header_line = '##INFO=<ID=GENE,Number=1,Type=String,Description="HGNC gene symbol">'
    File.open(header_file, 'w') {|f| f.write(header_line) }

    # Prepare BED file using bgzip and tabix
    `bgzip -c #{bed_file} > #{bed_file}.tmp.gz`
    `tabix -fp bed #{bed_file}.tmp.gz`

    # Add genes to VCF file
    tmp_output_file = "#{out_file_prefix}.tmp.vcf.gz"
    @@log.info("Adding gene annotations to #{tmp_output_file}")
    `bcftools annotate \
       --annotations #{bed_file}.tmp.gz \
       --columns CHROM,FROM,TO,GENE \
       --header-lines #{header_file} \
       --output #{tmp_output_file} \
       --output-type z \
       #{vcf_file}`
    @@log.info("Genes added to #{tmp_output_file}")

    # Move tmp output to be the new output file
    @addgenes_result = "#{out_file_prefix}.vcf.gz"
    @@log.info("Moving output to #{@addgenes_result}...")
    File.rename(tmp_output_file, @addgenes_result)

    # Create index
    @@log.info("Creating index for #{@addgenes_result}...")
    `bcftools index --force --tbi #{@addgenes_result}`
    @@log.info("Done creating index file")

    # Remove tmp files
    @@log.info("Removing all tmp files...")
    File.unlink(header_file) if File.exist?(header_file)
    File.unlink("#{bed_file}.tmp.gz") if File.exist?("#{bed_file}.tmp.gz")
    File.unlink("#{bed_file}.tmp.gz.tbi") if File.exist?("#{bed_file}.tmp.gz.tbi")
  end

  ##
  # Add predictions from dbNSFP
  ##
  def addpredictions(dbnsfp_file:, vcf_file:, bed_file:, out_file_prefix:, clinical_labels:)
    # Get only regions of interest from dbNSFP
    @@log.info("Subsetting dbNSFP for faster annotation...")
    dbnsfp_subset_file = "#{out_file_prefix}.dbNSFP_subset.tmp.bcf.gz"
    `bcftools view \
       --regions-file #{bed_file} \
       --output-type b \
       --output-file #{dbnsfp_subset_file} \
       #{dbnsfp_file['filename']}`
    @@log.info("dbNSFP subset written to #{dbnsfp_subset_file}")

    # Create index
    @@log.info("Creating index file for #{dbnsfp_subset_file}...")
    `bcftools index --force --csi #{dbnsfp_subset_file}`
    @@log.info("Done creating index file")

    # Add dbNSFP predictions
    tmp_output_file = "#{out_file_prefix}.tmp.vcf"
    f_tmp_output_file = File.open(tmp_output_file, 'w')
    @@log.info("Adding dbNSFP pedictions to #{tmp_output_file}...")
    `bcftools annotate \
       --annotations #{dbnsfp_subset_file} \
       --columns #{dbnsfp_file['fields'].map { |f| "INFO/#{f}" }.join(',')} \
       --output-type v \
       #{vcf_file}`.each_line do |vcf_row|
         vcf_row.chomp!
         if vcf_row.match(/^##/)
           # Print meta-info
           f_tmp_output_file.puts vcf_row
         elsif vcf_row.match(/^#[^#]/)
           f_tmp_output_file.puts "##INFO=<ID=#{@num_path_preds_tag},Number=.,Type=String,Description=\"Number of pathogenic predictions from dbNSFP\">"
           f_tmp_output_file.puts "##INFO=<ID=#{@total_num_preds_tag},Number=.,Type=String,Description=\"Total number of prediction scores available from dbNSFP\">"
           f_tmp_output_file.puts "##INFO=<ID=#{@final_pred_tag},Number=.,Type=String,Description=\"Final prediction consensus based on majority vote of prediction scores\">"

           # Add GERP++ prediction tag to meta-info
           if dbnsfp_file['fields'].any?{ |e| e == 'GERP_RS' }
             f_tmp_output_file.puts "##INFO=<ID=#{@gerp_pred_tag},Number=.,Type=String,Description=\"NA\">"
           end
           # Add phyloP20way mammalian prediction tag to meta-info
           if dbnsfp_file['fields'].any?{ |e| e == 'PHYLOP20WAY_MAMMALIAN' }
             f_tmp_output_file.puts "##INFO=<ID=#{@phylop20way_mammalian_pred_tag},Number=.,Type=String,Description=\"NA\">"
           end
           # Print header
           f_tmp_output_file.puts vcf_row
         else
           vcf_cols = vcf_row.split("\t")

           # Analyze each *_PRED field (as well as GERP++ and phyloP)
           # Tally up pathogenic predictions
           total_num_preds = 0
           num_path_preds = 0
           dbnsfp_file['fields'].select { |e| e.match(/(?:_PRED$|^GERP_RS$|^PHYLOP20WAY_MAMMALIAN$)/i) }.each do |field|
             # Get all predictions for this algorithm
             match = vcf_row.match(/(?:^|[\t;])#{Regexp.escape(field)}=([^;\t]*)/)

             # No data for this algorithm -- skip it
             next if match.nil?

             # Get all predictions for this algorithm
             preds = match[1].split(/[^a-zA-Z0-9.-]+/)

             # No data for this algorithm -- skip it
             next if preds.all? { |pred| pred == '.' || pred == 'U' }
               
             if field == 'SIFT_PRED'
               # SIFT prediction
               num_path_preds += 1 if preds.include?('D') # <-- "Damaging"
               total_num_preds += 1
             elsif field == 'POLYPHEN2_HDIV_PRED'
               # Polyphen2 (HDIV) prediction
               num_path_preds += 1 if preds.include?('D') || preds.include?('P') # <-- "Deleterious" or "Possibly damaging"
               total_num_preds += 1
             elsif field == 'LRT_PRED'
               # LRT prediction
               num_path_preds += 1 if preds.include?('D') # <-- "Deleterious"
               total_num_preds += 1
             elsif field == 'MUTATIONTASTER_PRED'
               # MutationTaster prediction
               num_path_preds += 1 if preds.include?('D') || preds.include?('A') # <-- "Disease-causing" or "Disease-causing (automatic)"
               total_num_preds += 1
             elsif field == 'GERP_RS'
               # GERP++ prediction
               if preds.any? { |pred| pred.to_f > 0.0 }
                 # Conserved
                 num_path_preds += 1
                 vcf_cols[7] = [vcf_cols[7], "#{@gerp_pred_tag}=C"].join(";")
               else
                 # Non-conserved
                 vcf_cols[7] = [vcf_cols[7], "#{@gerp_pred_tag}=N"].join(";")
               end
               total_num_preds += 1
             elsif field == 'PHYLOP20WAY_MAMMALIAN'
               # phyloP20way mammalian prediction
               if preds.any? { |pred| pred.to_f >= 0.95 }
                 # Conserved
                 num_path_preds += 1
                 vcf_cols[7] = [vcf_cols[7], "#{@phylop20way_mammalian_pred_tag}=C"].join(";")
               else
                 # Non-conserved
                 vcf_cols[7] = [vcf_cols[7], "#{@phylop20way_mammalian_pred_tag}=N"].join(";")
               end
               total_num_preds += 1
             end
           end

           # Add final prediction
           if total_num_preds == 0
             # No predictions available
             final_pred = '.'
             num_path_preds = '.'
             total_num_preds = '.'
           elsif total_num_preds >= 5
             path_score = num_path_preds.to_f/total_num_preds.to_f
             if path_score >= 0.6
               # Predicted pathogenic
               final_pred = URI.escape(clinical_labels['pred_pathogenic'])
             elsif path_score <= 0.4
               # Predicted benign
               final_pred = URI.escape(clinical_labels['pred_benign'])
             else
               # Predicted unknown (benign predictions approx. equal to pathogenic)
               final_pred = URI.escape(clinical_labels['unknown'])
             end
           else
             # Predicted unknown (not enough predictions)
             final_pred = URI.escape(clinical_labels['unknown'])
           end

           # Update INFO column
           if total_num_preds != 0 && total_num_preds != '.'
             vcf_cols[7] = [
               vcf_cols[7], 
               "#{@num_path_preds_tag}=#{num_path_preds}",
               "#{@total_num_preds_tag}=#{total_num_preds}", 
               "#{@final_pred_tag}=#{final_pred}",
             ].join(";")
           end

           # Print updated VCF row
           f_tmp_output_file.puts vcf_cols.join("\t")
         end
       end

    f_tmp_output_file.close
    @@log.info("Predictions added to #{tmp_output_file}")

    @addpredictions_result = "#{out_file_prefix}.vcf.gz"
    @@log.info("Compressing #{tmp_output_file}")
    # Compress the output file
    `bcftools view \
       --output-type z \
       --output-file #{@addpredictions_result} \
       #{tmp_output_file}`
    @@log.info("Compressed output written to #{@addpredictions_result}...")

    # Index output file
    @@log.info("Indexing #{@addpredictions_result}...")
    `bcftools index  \
       --force \
       --tbi \
       #{@addpredictions_result}`
    @@log.info("Done creating index file")

    @@log.info("Removing tmp files...")
    File.unlink(tmp_output_file) if File.exist?(tmp_output_file)
    File.unlink(dbnsfp_subset_file) if File.exist?(dbnsfp_subset_file)
    File.unlink("#{dbnsfp_subset_file}.csi") if File.exist?("#{dbnsfp_subset_file}.csi")
    @@log.info("Done removing tmp files")
  end

  ##
  # Finalize Pathogenicity
  ##
  def finalize_pathogenicity(vcf_file:, out_file_prefix:, clinical_labels:)
    @@log.debug("Finalizing pathogenicity...")
    tmp_output_file = "#{out_file_prefix}.tmp.vcf"
    f_tmp_output_file = File.open(tmp_output_file, 'w')

    # Initialize final pathogenicity fields
    final = {}
    final[:pathogenicity] = '.'
    final[:diseases] = '.'
    final[:source] = '.'
    final[:pmids] = '.'
    final[:reason] = '.'
    final[:comments] = '.'

    # Set ClinVar pathogenicity dictionary
    clinvar_pathogenicity_map = {
      '2' => clinical_labels['benign'],
      '3' => clinical_labels['likely_benign'],
      '4' => clinical_labels['likely_pathogenic'],
      '5' => clinical_labels['pathogenic'],
      'Benign' => clinical_labels['benign'],
      'Likely benign' => clinical_labels['likely_benign'],
      'Likely pathogenic' => clinical_labels['likely_pathogenic'],
      'Pathogenic' => clinical_labels['pathogenic'],
    }

    # Clinical confidence/review weight
    clinvar_confidence_weight = {
      'not'    => 0,
      'single' => 1,
      'mult'   => 2,
      'exp'    => 3,
      'prof'   => 4,
      'classified by multiple submitters' => 2,
    }

    # Set HGMD pathogenicity dictionary
    hgmd_pathogenicity_map = {
      'DM'  => clinical_labels['pathogenic'], # Disease mutation
      'DM?' => clinical_labels['unknown'],    # Possible disease mutation
      'DP'  => clinical_labels['benign'],     # Disease-associated polymorphism
      'DFP' => clinical_labels['benign'],     # Disease-associated polymorphism with additional supporting functional evidence
      'FP'  => clinical_labels['benign'],     # In vitro/laboratory or in vivo functional polymorphism
      'FTV' => clinical_labels['benign'],     # Frameshift / truncating variant 
      'CNV' => clinical_labels['benign'],     # Copy number variation
      'R'   => clinical_labels['unknown'],    # Removed from HGMD
    }

    # HGMD confidence weight
    hgmd_confidence_weight = {
      'Low'  => 1,
      'High' => 2,
    }

    @@log.info("Adding final pathogenicity to #{tmp_output_file}...")
    `bcftools view \
       --output-type v \
       #{vcf_file}`.each_line do |vcf_row|
         vcf_row.chomp!
         if vcf_row.match(/^##/)
           # Print meta-info
           f_tmp_output_file.puts vcf_row
         elsif vcf_row.match(/^#[^#]/)
           # Add new tags to meta-info
           f_tmp_output_file.puts "##INFO=<ID=#{@final_pathogenicity_tag},Number=.,Type=String,Description=\"Final curated pathogenicity\">"
           f_tmp_output_file.puts "##INFO=<ID=#{@final_diseases_tag},Number=.,Type=String,Description=\"Final curated disease\">"
           f_tmp_output_file.puts "##INFO=<ID=#{@final_pathogenicity_source_tag},Number=.,Type=String,Description=\"Source for final pathogenicity\">"
           f_tmp_output_file.puts "##INFO=<ID=#{@final_pmids_tag},Number=.,Type=String,Description=\"PubMed IDs\">"
           f_tmp_output_file.puts "##INFO=<ID=#{@final_pathogenicity_reason_tag},Number=.,Type=String,Description=\"Brief reason for final pathogenicity\">"
           f_tmp_output_file.puts "##INFO=<ID=#{@final_comments_tag},Number=.,Type=String,Description=\"Additional comments from curator\">"
           f_tmp_output_file.puts "##INFO=<ID=#{@clinvar_hgmd_conflict_tag},Number=.,Type=String,Description=\"ClinVar and HGMD disagree (0 - No, 1 - Yes)\">"

           # Print header
           f_tmp_output_file.puts vcf_row
         else
           vcf_cols = vcf_row.split("\t")
           @@log.debug("Processing: #{vcf_cols[0]}\t#{vcf_cols[1]}\t#{vcf_cols[3]}\t#{vcf_cols[4]}")

           # Initialize final pathogenicity fields
           final = {}
           final[:pathogenicity] = clinical_labels['unknown']
           final[:diseases] = '.'
           final[:source] = "."
           final[:pmids] = '.'
           final[:clinvar_hgmd_conflict] = '.'
           final[:reason] = '.'   # <- This field is for internal use only
           final[:comments] = '.' # <- Comments are for public and internal use

           # TODO Finalize pathogenicity
           #if (vcf_cols[7].match(/(?:^|[\t;])(?:MORL|CURATED)_PATHOGENICITY=([^;\t]*)/)).nil?
           if vcf_cols[7].scan(/(?:^|[\t;])(?:MORL|CURATED)_PATHOGENICITY=([^;\t]*)/).flatten.any? { |p| p != '.'  } == true
             @@log.debug("- Pathogenicity is based on expert curation")
             # NOTE: THIS SECTION IS DONE!
             # ^Check for expert-curated pathogenicity
             final[:pathogenicity] = vcf_cols[7].scan(/(?:^|[\t;])(?:MORL|CURATED)_PATHOGENICITY=([^;\t]*)/)
             final[:diseases] = vcf_cols[7].scan(/(?:^|[\t;])(?:MORL|CURATED)_PATHOGENICITY=([^;\t]*)/)
             final[:pmids] = vcf_cols[7].scan(/(?:^|[\t;])(?:MORL|CURATED)_PMID=([^;\t]*)/)
             final[:source] = "Expert-curated"
             final[:reason] = URI.escape("This variant has been expertly curated.")
             final[:comments] = vcf_cols[7].scan(/(?:^|[\t;])(?:MORL|CURATED)_COMMENTS=([^;\t]*)/)
           elsif vcf_cols[7].scan(/[^;\t]*_?AF=([^;\t]*)/).flatten.any? { |af| af.to_f >= 0.005 } == true
             @@log.debug("- Pathogenicity is based on MAF (>=0.005 in at least one population)")

             # NOTE: THIS SECTION IS DONE!
             # ^Check if max MAF >= 0.005
             final[:pathogenicity] = URI.escape(clinical_labels['benign'])
             final[:diseases] = "."
             final[:pmids] = "."
             final[:source] = "MAF"
             final[:reason] = "MAF_gte_0.005"
             final[:comments] = URI.escape("This variant contains a MAF greater than 0.005 in at least one population and is therefore labeled as \"#{clinical_labels['benign'].gsub('_', ' ')}\"")
           elsif !(vcf_cols[7].match(/(?:^|[\t;])(?:CLINVAR_CLINICAL_SIGNIFICANCE|(?:HGMD_)?VARIANTTYPE)=(?:[^;\t]*)/)).nil?
             # NOTE: ALL FIELD RETRIEVAL AND FORMATTING IS DONE BELOW!
             # ^Check for HGMD / ClinVar pathogenicity
             
             # Get ClinVar pathogenicities
             clinvar = {}
             clinvar[:all_pathogenicities] = vcf_cols[7].scan(/(?:^|[\t;])CLINVAR_CLINICAL_SIGNIFICANCE=([^;\t]*)/).flatten[0].to_s

             # Get ClinVar diseases, and...
             # 1.) Remove duplicates
             # 2.) Remove values that are (a) 'not_specified' or (b) 'AllHighlyPenetrant'
             clinvar[:diseases] = vcf_cols[7].scan(/(?:^|[\t;])CLINVAR_ALL_TRAITS=([^;\t]*)/).flatten[0].to_s.split(/[,|]/).uniq.delete_if { |e| e.match(/^(?:not_specified|AllHighlyPenetrant)$/) }.join('|')

             # Get ClinVar PMIDs (remove leading/trailing characters such as whitespace and commas
             clinvar[:pmids] = vcf_cols[7].scan(/(?:^|[\t;])CLINVAR_ALL_PMIDS=([^;\t]*)/).flatten[0].to_s.gsub(/^[^0-9]+|[^0-9]+$/, '').gsub(/\D+/, '|')

             # Get ClinVar submission conflicts
             clinvar[:conflicted] = vcf_cols[7].scan(/(?:^|[\t;])CLINVAR_CONFLICTED=([^;\t]*)/).flatten[0].to_s

             # Translate ClinVar pathogenicity
             if !clinvar[:all_pathogenicities].empty?
               if !(clinvar[:all_pathogenicities].match(/(?:^|[,|;])Pathogenic(?:[,|;]|$)/i)).nil?
                 # Pathogenic
                 clinvar[:worst_pathogenicity] = clinical_labels['pathogenic']
               elsif !(clinvar[:all_pathogenicities].match(/(?:^|[,|;])Likely[-_ ]pathogenic(?:[,|;]|$)/i)).nil?
                 # Likely pathogenic
                 clinvar[:worst_pathogenicity] = clinical_labels['likely_pathogenic']
               elsif !(clinvar[:all_pathogenicities].match(/(?:^|[,|;])Likely[-_ ](?:benign|non[-_ ]?pathogenic)(?:[,|;]|$)/i)).nil?
                 # Likely benign
                 clinvar[:worst_pathogenicity] = clinical_labels['likely_benign']
               elsif !(clinvar[:all_pathogenicities].match(/(?:^|[,|;])(?:Benign|Non[-_ ]?pathogenic)(?:[,|;]|$)/i)).nil?
                 # Benign
                 clinvar[:worst_pathogenicity] = clinical_labels['benign']
               else
                 # Unknown significance
                 clinvar[:worst_pathogenicity] = clinical_labels['unknown']
               end
             else
               # Unknown significance
               clinvar[:worst_pathogenicity] = ""
             end

             # HGMD fields
             hgmd = {}
             hgmd[:pathogenicity] = hgmd_pathogenicity_map[vcf_cols[7].scan(/(?:^|[\t;])(?:HGMD_)?VARIANTTYPE=([^;\t]*)/).flatten[0]].to_s
             hgmd[:diseases] = vcf_cols[7].scan(/(?:^|[\t;])(?:HGMD_)?DISEASE=([^;\t]*)/).flatten[0].to_s
             hgmd[:pmids] = vcf_cols[7].scan(/(?:^|[\t;])(?:HGMD_)?PMID=([^;\t]*)/).flatten[0].to_s.gsub(/\D+/, '|')
             hgmd[:confidence] = vcf_cols[7].scan(/(?:^|[\t;])(?:HGMD_)?CONFIDENCE=([^;\t]*)/).flatten[0].to_s

             # Finalize pathogenicity fields...
             if !clinvar[:worst_pathogenicity].empty? && hgmd[:pathogenicity].empty?
               # NOTE: THIS SECTION IS DONE!
               # ^Only found in ClinVar
               @@log.debug("- Pathogenicity is based on ClinVar submissions only")
               final[:pathogenicity] = clinvar[:worst_pathogenicity]
               final[:diseases] = clinvar[:diseases]
               final[:source] = "ClinVar"
               final[:pmids] = clinvar[:pmids]
               final[:reason] = URI.escape("Found in ClinVar but not in HGMD")
               final[:comments] = URI.escape("Pathogenicity is based on ClinVar submissions.")
               # Add notes about submission conflicts (if any)
               if clinvar[:conflicted] != '0'
                 final[:comments] += URI.escape(" Please note that not all submitters agree with this pathogenicity.")
               else
                 final[:comments] += URI.escape(" All submitters agree with this pathogenicity.")
               end
             elsif !hgmd[:pathogenicity].empty? && clinvar[:worst_pathogenicity].empty?
               # NOTE: THIS SECTION IS DONE!
               # ^Only found in HGMD
               @@log.debug("- Pathogenicity is based on HGMD only")
               final[:pathogenicity] = hgmd[:pathogenicity]
               final[:diseases] = hgmd[:diseases]
               final[:source] = "HGMD"
               final[:pmids] = hgmd[:pmids]
               final[:reason] = URI.escape("Found in HGMD but not in ClinVar")
               final[:comments] = URI.escape("Pathogenicity is based on the literature provided in PubMed.")
             elsif !clinvar[:worst_pathogenicity].empty? && !hgmd[:pathogenicity].empty?
               # TODO ^Found in ClinVar and HGMD
               @@log.debug("- Pathogenicity is based on ClinVar and HGMD")
               if clinvar[:worst_pathogenicity] == hgmd[:pathogenicity]
                 # ClinVar and HGMD agree
                 final[:pathogenicity] = clinvar[:worst_pathogenicity]
                 final[:diseases] = hgmd[:diseases]
                 final[:source] = "ClinVar/HGMD"
                 final[:pmids] = [clinvar[:pmids], hgmd[:pmids]].split(/\D+/).uniq.join('|')
                 final[:reason] = URI.escape("Found in HGMD but not in ClinVar")
                 final[:comments] = URI.escape("Pathogenicity is based on the literature provided in PubMed.")
                 final[:clinvar_hgmd_conflict] = 0
               else
                 # ClinVar and HGMD disagree
                 final[:pathogenicity] = clinical_labels[:unknown]
                 final[:source] = "ClinVar/HGMD_conflict"
                 final[:reason] = "ClinVar/HGMD_conflict"
                 final[:comments] = URI.escape("Pathogenicity is based on the literature provided in PubMed.")
                 final[:clinvar_hgmd_conflict] = 1
               end
             else
               # ^Not found in ClinVar or HGMD
               @@log.warn("- SOMETHING WENT WRONG")
               final[:pathogenicity] = URI.escape(clinical_labels['unknown'])
               final[:source] = "."
               final[:reason] = URI.escape("Not enough information")
             end
           elsif !(match = vcf_cols[7].scan(/(?:^|[\t;])#{@final_pred_tag}=([^;\t]*)/).flatten[0]).nil? && match != '.'
             @@log.debug("- Pathogenicity is based on predictions from dbNSFP")
             # ^Use dbNSFP prediction
             if match == clinical_labels['unknown']
               # NOTE: THIS SECTION IS DONE!
               # ^Not enough prediction data
               final[:pathogenicity] = clinical_labels['unknown']
               final[:diseases] = '.'
               final[:source] = '.'
               final[:pmids] = '.'
               final[:reason] = URI.escape("Not enough information")
               final[:comments] = '.'
               @@log.debug("- Not enough predictions")
             else
               # NOTE: THIS SECTION IS DONE!
               # ^Set final pathogenicity as predicted pathogenicity
               final[:pathogenicity] = match
               final[:diseases] = '.'
               final[:source] = "dbNSFP"
               final[:pmids] = '.'
               if !(num_path_preds = vcf_cols[7].scan(/(?:^|[\t;])#{@num_path_preds_tag}=([^;\t]*)/).flatten[0]).nil?
                 # Get pathogenic prediction fraction
                 if num_path_preds != '.' && num_path_preds != '0'
                   total_num_preds = vcf_cols[7].scan(/(?:^|[\t;])#{@total_num_preds_tag}=([^;\t]*)/).flatten[0]
                   path_pred_fraction = "#{num_path_preds}/#{total_num_preds}"
                   final[:reason] = URI.escape("#{num_path_preds}/#{total_num_preds} pathogenic")
                   final[:comments] = URI.escape("Pathogenicity is based on prediction data only. #{num_path_preds} out of #{total_num_preds} predictions were pathogenic.")
                   @@log.debug("- #{num_path_preds}/#{total_num_preds} pathogenic predictions")
                 end
               else
                 # Could not find prediction numbers (ideally this should never happen)
                 final[:reason] = URI.escape("Pathogenicity is based on prediction data only.")
                 final[:comments] = URI.escape("Pathogenicity is based on prediction data only.")
                 @@log.warn("- PREDICTION COUNTS WERE NOT FOUND")
               end
             end
           else
             # Unknown significance
             @@log.debug("- This variant is a VUS because it does not have enough info")
             final[:pathogenicity] = clinical_labels['unknown']
             final[:reason] = URI.escape("Not enough information")
             final[:comments] = URI.escape("This variant is a VUS because it does not have enough info")
           end

           # NOTE: THIS SECTION (ALL FINAL PRINTING) IS DONE
           # Update INFO column
           vcf_cols[7] = [
             vcf_cols[7],
             "#{@final_pathogenicity_tag}=#{final[:pathogenicity]}",
             "#{@final_pmids_tag}=#{final[:pmids]}",
             "#{@final_comments_tag}=#{final[:comments]}",
             "#{@final_pathogenicity_source_tag}=#{final[:source]}",
             "#{@final_pathogenicity_reason_tag}=#{final[:reason]}",
             "#{@final_diseases_tag}=#{final[:diseases]}",
             "#{@clinvar_hgmd_conflict_tag}=#{final[:clinvar_hgmd_conflict]}",
           ].join(";")
           
           # Print updated VCF row
           f_tmp_output_file.puts vcf_cols.join("\t")

           @@log.debug("- This variant is labeled \"#{final[:pathogenicity]}\"")
           @@log.debug("------------------------------------------------------")
         end

       end
    #  ^End of parsing bcftools result & printing new record

    f_tmp_output_file.close

    @@log.info("Final pathogenicity added to #{tmp_output_file}")

    @finalize_pathogenicity_result = "#{out_file_prefix}.vcf.gz"
    @@log.info("Compressing #{tmp_output_file}...")
    # Compress the output file
    `bcftools view \
       --output-type z \
       --output-file #{@finalize_pathogenicity_result} \
       #{tmp_output_file}`
    @@log.info("Compressed output written to #{@finalize_pathogenicity_result}")

    # Index output file
    @@log.info("Indexing #{@finalize_pathogenicity_result}...")
    `bcftools index  \
       --force \
       --tbi \
       #{@finalize_pathogenicity_result}`
    @@log.info("Done creating index file")

    @@log.info("Removing tmp files...")
    File.unlink(tmp_output_file) if File.exist?(tmp_output_file)
    @@log.info("Done removing tmp files")
  end
end
