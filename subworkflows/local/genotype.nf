//
// Genotype the input data using the requested genotyper.
//

include { SAMTOOLS_MPILEUP as SAMTOOLS_MPILEUP_PILEUPCALLER } from '../../modules/nf-core/samtools/mpileup/main'
include { EIGENSTRATDATABASETOOLS_EIGENSTRATSNPCOVERAGE     } from '../../modules/nf-core/eigenstratdatabasetools/eigenstratsnpcoverage/main'
include { SEQUENCETOOLS_PILEUPCALLER                        } from '../../modules/nf-core/sequencetools/pileupcaller/main'
include { GATK_REALIGNERTARGETCREATOR                       } from '../../modules/nf-core/gatk/realignertargetcreator/main'
include { GATK_INDELREALIGNER                               } from '../../modules/nf-core/gatk/indelrealigner/main'
include { GATK_UNIFIEDGENOTYPER                             } from '../../modules/nf-core/gatk/unifiedgenotyper/main'
include { GATK4_HAPLOTYPECALLER                             } from '../../modules/nf-core/gatk4/haplotypecaller/main'
include { FREEBAYES                                         } from '../../modules/nf-core/freebayes/main'
include { BCFTOOLS_STATS as BCFTOOLS_STATS_GENOTYPING       } from '../../modules/nf-core/bcftools/stats/main'
// TODO Add ANGSD GTL module. The current module does not pick up the .glf.gz output files.

workflow GENOTYPE {
    take:
    ch_bam_bai                // [ [ meta ], bam , bai ]
    ch_fasta_plus             // [ [ meta ], fasta, fai, dict ]
    ch_pileupcaller_aux_files // [ [ meta ], bed, snp ]
    ch_dbsnp                  // [ [ meta ], dbsnp ]

    main:
    ch_versions                        = Channel.empty()
    ch_multiqc_files                   = Channel.empty()
    ch_pileupcaller_genotypes          = Channel.empty()
    ch_gatk_haplotypecaller_genotypes  = Channel.empty()
    ch_gatk_unifiedgenotyper_genotypes = Channel.empty()
    ch_freebayes_genotypes             = Channel.empty()
    ch_angsd_genotypes                 = Channel.empty()
    ch_bcftools_stats                  = Channel.empty()

    // Replace missing dbsnps with empty lists
    ch_dbsnp_for_gatk = ch_dbsnp
        .map {
            meta, dbsnp ->
            final_dbsnp = dbsnp != "" ? dbsnp : []
            [ meta, final_dbsnp ]
        }

    if ( params.genotyping_tool == 'pileupcaller' ) {

        // Compile together all reference based files
        ch_refs_for_mpileup_pileupcaller = ch_fasta_plus
            .join( ch_pileupcaller_aux_files ) // [ [ref_meta], fasta, fai, dict, bed, snp ]
            .map {
            // Prepend a new meta that contains the meta.id value as the new_meta.reference attribute
                WorkflowEager.addNewMetaFromAttributes( it, "id" , "reference" , false )
            } // RESULT: [ [combination_meta], [ref_meta], fasta, fai, dict, bed, snp ]

        // Prepare collect bams for mpileup
        ch_mpileup_inputs_bams = ch_bam_bai
            .map {
                WorkflowEager.addNewMetaFromAttributes( it, ["reference", "strandedness"] , ["reference", "strandedness"] , false )
            }
            .groupTuple()
            .map {
                combo_meta, metas, bams, bais ->
                def ids = metas.collect { meta -> meta.id }
                [ combo_meta + [id: ids], bams ] // Drop bais
            } // Collect all IDs into a list in meta.id. Useful when running pileupCaller later

            // Combine prepped bams and references
            ch_mpileup_inputs = ch_mpileup_inputs_bams
                .map {
                    WorkflowEager.addNewMetaFromAttributes( it, "reference", "reference" , false )
                }
                .combine( ch_refs_for_mpileup_pileupcaller , by:0 )
                .multiMap {
                    ignore_me, combo_meta, bams, ref_meta, fasta, fai, dict, bed, snp ->
                        def bedfile = bed != "" ? bed : []
                        bams:  [ combo_meta, bams, bedfile ]
                        fasta: [ fasta ]
                }
            SAMTOOLS_MPILEUP_PILEUPCALLER(
                ch_mpileup_inputs.bams,
                ch_mpileup_inputs.fasta
            )
            ch_versions = ch_versions.mix( SAMTOOLS_MPILEUP_PILEUPCALLER.out.versions.first() )

            ch_pileupcaller_input = SAMTOOLS_MPILEUP_PILEUPCALLER.out.mpileup
                .map {
                    WorkflowEager.addNewMetaFromAttributes( it, "reference", "reference" , false )
                }
                .combine( ch_refs_for_mpileup_pileupcaller, by:0 )
                .multiMap {
                    ignore_me, meta, mpileup, ref_meta, fasta, fai, dict, bed, snp ->
                        def snpfile = snp != "" ? snp : []
                        mpileup: [ meta, mpileup ]
                        snpfile: [ snpfile ]
                }

            // TODO NOTE: Maybe implement a check that unmerged R2 reads have not been kept and throw a warning for ssDNA libs? See: https://github.com/stschiff/sequenceTools/issues/24
            ch_pileupcaller_input.mpileup.dump(tag:"mpileup", pretty: true)
            // Run PileupCaller
            SEQUENCETOOLS_PILEUPCALLER(
                ch_pileupcaller_input.mpileup,
                ch_pileupcaller_input.snpfile,
                []
            )
            ch_versions = ch_versions.mix( SEQUENCETOOLS_PILEUPCALLER.out.versions.first() )
    }

    if ( params.genotyping_tool == 'ug' ) {
        // Use correct reference for each input bam/bai pair.
        ch_bams_for_multimap = ch_bam_bai
            .map {
            // Prepend a new meta that contains the meta.reference value as the new_meta.reference attribute
                WorkflowEager.addNewMetaFromAttributes( it, "reference" , "reference" , false )
            }

        ch_fasta_for_multimap = ch_fasta_plus
            .join( ch_dbsnp_for_gatk ) // [ [ref_meta], fasta, fai, dict, dbsnp ]
            .map {
            // Prepend a new meta that contains the meta.id value as the new_meta.reference attribute
                WorkflowEager.addNewMetaFromAttributes( it, "id" , "reference" , false )
            } // RESULT: [ [combination_meta], [ref_meta], fasta, fai, dict, dbsnp ]

        ch_input_for_targetcreator = ch_bams_for_multimap
            .combine( ch_fasta_for_multimap , by:0 )
            .multiMap {
                ignore_me, meta, bam, bai, ref_meta, fasta, fai, dict, dbsnp ->
                    bam:   [ meta, bam , bai ]
                    fasta: [ ref_meta, fasta ]
                    fai:   [ ref_meta, fai ]
                    dict:  [ ref_meta, dict ]
            }

        GATK_REALIGNERTARGETCREATOR(
            ch_input_for_targetcreator.bam,
            ch_input_for_targetcreator.fasta,
            ch_input_for_targetcreator.fai,
            ch_input_for_targetcreator.dict,
            [[], []] // No known_vcf
        )
        ch_versions = ch_versions.mix( GATK_REALIGNERTARGETCREATOR.out.versions.first() )

        // Join the bam/bai pairs to the intervals file, then redo multiMap to get the correct ordering for each bam/reference/intervals set.
        ch_input_for_indelrealigner = ch_bam_bai
            .join( GATK_REALIGNERTARGETCREATOR.out.intervals )
            .map {
            // Prepend a new meta that contains the meta.reference value as the new_meta.reference attribute
                WorkflowEager.addNewMetaFromAttributes( it, "reference" , "reference" , false )
            }
            .combine( ch_fasta_for_multimap , by:0 )
            .multiMap {
                ignore_me, meta, bam, bai, intervals, ref_meta, fasta, fai, dict, dbsnp ->
                    bam:   [ meta, bam, bai, intervals ]
                    fasta: [ ref_meta, fasta ]
                    fai:   [ ref_meta, fai ]
                    dict:  [ ref_meta, dict ]
            }

        GATK_INDELREALIGNER(
            ch_input_for_indelrealigner.bam,
            ch_input_for_indelrealigner.fasta,
            ch_input_for_indelrealigner.fai,
            ch_input_for_indelrealigner.dict,
            [[], []] // No known_vcf
        )
        ch_versions = ch_versions.mix( GATK_INDELREALIGNER.out.versions.first() ) // TODO is this actually needed, since all GATK modules have the same version?

        // Use realigned bams as input for UG. combine with reference info to get correct ordering.
        ch_bams_for_ug = GATK_INDELREALIGNER.out.bam
            .map {
                WorkflowEager.addNewMetaFromAttributes( it, "reference" , "reference" , false )
            }
            .combine( ch_fasta_for_multimap , by:0 )
            .multiMap {
                ignore_me, meta, bam, bai, ref_meta, fasta, fai, dict, dbsnp ->
                    bam:   [ meta, bam, bai ]
                    fasta: [ ref_meta, fasta ]
                    fai:   [ ref_meta, fai ]
                    dict:  [ ref_meta, dict ]
                    dbsnp: [ ref_meta, dbsnp ]
            }

        // TODO: Should the vcfs be indexed with bcftools index? VCFs from HC are indexed.
        GATK_UNIFIEDGENOTYPER(
            ch_bams_for_ug.bam,
            ch_bams_for_ug.fasta,
            ch_bams_for_ug.fai,
            ch_bams_for_ug.dict,
            [[], []], // No intervals
            [[], []], // No contamination
            ch_bams_for_ug.dbsnp,
            [[], []]  // No comp
        )
        ch_versions = ch_versions.mix( GATK_UNIFIEDGENOTYPER.out.versions.first() )
        ch_gatk_unifiedgenotyper_genotypes = GATK_UNIFIEDGENOTYPER.out.vcf
    }

    if ( params.genotyping_tool == 'hc' ) {
        ch_bams_for_multimap = ch_bam_bai
            .map {
            // Prepend a new meta that contains the meta.reference value as the new_meta.reference attribute
                WorkflowEager.addNewMetaFromAttributes( it, "reference" , "reference" , false )
            }

        ch_fasta_for_multimap = ch_fasta_plus
            .join( ch_dbsnp_for_gatk ) // [ [ref_meta], fasta, fai, dict, dbsnp ]
            .map {
            // Prepend a new meta that contains the meta.id value as the new_meta.reference attribute
                WorkflowEager.addNewMetaFromAttributes( it, "id" , "reference" , false )
            } // RESULT: [ [combination_meta], [ref_meta], fasta, fai, dict, dbsnp ]

        ch_input_for_hc = ch_bams_for_multimap
            .combine( ch_fasta_for_multimap , by:0 )
            .multiMap {
                ignore_me, meta, bam, bai, ref_meta, fasta, fai, dict, dbsnp ->
                    bam:   [ meta, bam , bai, [], [] ] // No intervals or dragSTR model inputs to HC module
                    fasta: [ ref_meta, fasta ]
                    fai:   [ ref_meta, fai ]
                    dict:  [ ref_meta, dict ]
                    dbsnp: [ ref_meta, dbsnp ]
            }

        GATK4_HAPLOTYPECALLER(
            ch_input_for_hc.bam,
            ch_input_for_hc.fasta,
            ch_input_for_hc.fai,
            ch_input_for_hc.dict,
            ch_input_for_hc.dbsnp,
            [[], []] // No dbsnp_tbi
        )
        ch_versions = ch_versions.mix( GATK4_HAPLOTYPECALLER.out.versions.first() )
        ch_gatk_unifiedgenotyper_genotypes = GATK4_HAPLOTYPECALLER.out.vcf
    }

    if ( params.genotyping_tool == 'freebayes' ) {
        ch_bams_for_multimap = ch_bam_bai
            .map {
            // Prepend a new meta that contains the meta.reference value as the new_meta.reference attribute
                WorkflowEager.addNewMetaFromAttributes( it, "reference" , "reference" , false )
            }

        // TODO Do we want to provide SNP capture bed file to Freebayes? It would then genotype only on those positions.
        // NOTE: dbsnp is not used by Freebayes, but we need to provide it to the module anyway, to ensure correct cardinality of the fasta channel within the BCFTOOLS_STATS channel operations.
        ch_fasta_for_multimap = ch_fasta_plus
            .join( ch_dbsnp_for_gatk ) // [ [ref_meta], fasta, fai, dict, dbsnp ]
            .map {
            // Prepend a new meta that contains the meta.id value as the new_meta.reference attribute
                WorkflowEager.addNewMetaFromAttributes( it, "id" , "reference" , false )
            } // RESULT: [ [combination_meta], [ref_meta], fasta, fai, dict, dbsnp ]

        ch_input_for_freebayes = ch_bams_for_multimap
            .combine( ch_fasta_for_multimap , by:0 )
            .multiMap {
                ignore_me, meta, bam, bai, ref_meta, fasta, fai, dict, dbsnp ->
                    bam:   [ meta, bam , bai, [], [], [] ] // No second bam, second bai, or regions-BED file
                    fasta: [ ref_meta, fasta ]
                    fai:   [ ref_meta, fai ]
            }

        // TODO: Should the vcfs be indexed with bcftools index? VCFs from HC are indexed.
        FREEBAYES(
            ch_input_for_freebayes.bam,
            ch_input_for_freebayes.fasta,
            ch_input_for_freebayes.fai,
            [ [], [] ], // No samples file
            [ [], [] ], // No populations file
            [ [], [] ]  // No CNV file
            )
        ch_versions = ch_versions.mix( FREEBAYES.out.versions.first() )
        ch_freebayes_genotypes = FREEBAYES.out.vcf
    }

    if ( params.genotyping_tool == 'angsd' ) {
        // TODO no module for angsd genotyping yet
    }

    // Run BCFTOOLS_STATS on output from GATK UG, HC and Freebayes
    if ( !params.skip_bcftools_stats && ( params.genotyping_tool == 'hc' || params.genotyping_tool == 'ug' || params.genotyping_tool == 'freebayes' ) ) {
        ch_bcftools_input= ch_gatk_unifiedgenotyper_genotypes
            .mix( ch_gatk_haplotypecaller_genotypes )
            .mix( ch_freebayes_genotypes )
            .map {
                WorkflowEager.addNewMetaFromAttributes( it, "reference" , "reference" , false )
            }
            .combine( ch_fasta_for_multimap , by:0 )
            .multiMap {
                ignore_me, meta, vcf, ref_meta, fasta, fai, dict, dbsnp ->
                    vcf:   [ meta, vcf, [] ] // bcftools stats module expects a tbi file with the vcf.
                    fasta: [ ref_meta, fasta ]
            }

        BCFTOOLS_STATS_GENOTYPING(
            ch_bcftools_input.vcf,  // vcf
            [ [], [] ],             // regions
            [ [], [] ],             // targets
            [ [], [] ],             // samples
            [ [], [] ],             // exons
            ch_bcftools_input.fasta // fasta
        )
        ch_versions = ch_versions.mix( BCFTOOLS_STATS_GENOTYPING.out.versions.first() )
    }

    emit:
    geno_pileupcaller = ch_pileupcaller_genotypes          // [ [ meta ], geno, snp, ind ]
    geno_gatk_hc      = ch_gatk_haplotypecaller_genotypes  // [ [ meta ], vcf ] ]
    geno_gatk_ug      = ch_gatk_unifiedgenotyper_genotypes // [ [ meta ], vcf ] ]
    geno_freebayes    = ch_freebayes_genotypes             // [ [ meta ], vcf ] ]
    geno_angsd        = ch_angsd_genotypes                 // [ [ meta ], glf ] ]
    versions          = ch_versions
    mqc               = ch_multiqc_files

}
