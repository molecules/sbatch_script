#!/storage/htc/biocompute/ircf/apps/rakudo-star/rakudo-star-2018.01/install/bin/perl6
#sbatch_script

# job and wrap as positional parameters, the rest as named parameters
sub MAIN (
#= Create and run an sbatch script
    Str       $job,                           #= Job name (only alphanumeric, dash, or underscore allowed)
    Str       $wrap,                          #= Command to execute
    Int      :$cpu=1,                         #= Number of cores to use . default: 1
    Str      :$mem='10G',                     #= Total RAM to allocate. . default: "10G"
    Str      :$time='1-0:00:00',              #= Time limit . . . . . . . default: "1-0:00:00", meaning 1 day, 0 hours, 00 minutes, 00 seconds
    Str      :$partition,                     #= partition to use
    Str      :$job-files-dir='job_files.dir', #= job log directory. . . . default: "job_files.dir"
    Str      :$dependency,                    #= list of jobs that must finish before this one starts
    Str      :$sarray-file-pattern,           #= Pattern of files to include in sarray (use $FILE in your script to refer to a file)
    Str      :$sarray-paired-file-pattern,    #= Pattern of paired files to include in sarray (use $PAIRED_FILE in your script to refer to a paired file)
    Bool     :$script-only=False,             #= Create the script, but don't run it
    Bool     :$sarray-limit,                  #= Number of simultaneous jobs to allow to run at the same time
)
{

    # Paired file pattern is meaningless if it lacks something to pair with
    if $sarray-paired-file-pattern && ! $sarray-file-pattern {
        note '--sarray-paired-file-pattern requires --sarray-file-pattern';
        exit;
    }

    mkdir $job-files-dir;
    my $job_script_name = job_script_name_for($job);
    my $batch_code      = batch_code(:$mem, :$cpu, :$wrap, :$job, :$time, :$partition, :$job-files-dir, :$dependency, :$sarray-file-pattern, :$sarray-paired-file-pattern, :$sarray-limit);

    # Write batch file
    spurt($job_script_name, $batch_code);

    unless ( $script-only )
    {
        # Run batch file
        run("sbatch", $job_script_name);
    }
}

# Create the text for a batch script
sub batch_code ( :$wrap, :$cpu, :$mem, :$job, :$time, :$partition, :$job-files-dir, :$dependency, :$sarray-file-pattern, :$sarray-paired-file-pattern, :$sarray-limit)
{
    # Create batch header
    my $header = batch_header( :$cpu, :$mem, :$job, :$time, :$partition, :$job-files-dir, :$dependency, :$sarray-file-pattern, :$sarray-paired-file-pattern, :$sarray-limit);

    # Add body to code
    my $code = "$header\n";

    # separate statements into separate lines
    my @lines = $wrap.subst(/ \s* \; \s* /,"\n", :global);

    $code~= @lines.join("\n") ~ "\n";

    return $code;
}

sub batch_header ( :$cpu, :$mem, :$job, :$time, :$partition, :$job-files-dir, :$dependency, :$sarray-file-pattern, :$sarray-paired-file-pattern, :$sarray-limit )
{
    my $header = qq:heredoc/END/;
        #!/bin/env bash
        #SBATCH -J $job
        #SBATCH --mem $mem
        #SBATCH --cpus-per-task $cpu
        #SBATCH --ntasks 1
        #SBATCH --nodes 1
        #SBATCH --time $time
        END

    $header ~= "#SBATCH --partition  $partition\n"  if $partition;
    $header ~= "#SBATCH --dependency $dependency\n" if $dependency;

    # Job file names
    if $sarray-file-pattern {
        $header ~= "#SBATCH -o $job-files-dir/$job.oe_%A_%a\n";
    }
    else {
        $header ~= "#SBATCH -o $job-files-dir/$job.oe_%j\n";
    }

    if $sarray-file-pattern {

        my @filenames = sorted-filenames-matching($sarray-file-pattern);

        my $generated-sarray = '0-' ~ @filenames.end;
        $generated-sarray ~= '%' ~ $sarray-limit if $sarray-limit; 
        $header ~= "#SBATCH --array=$generated-sarray\n";

        #WARNING: Below is actually body, not header
        $header ~= 'FILES=('
                 ~ @filenames.join(' ')
                 ~ ')'
                 ~ "\n\n";

        $header ~= 'FILE=${FILES[$SLURM_ARRAY_TASK_ID]}' ~ "\n";

        # If paired, check that there are equal numbers of paired files
        if $sarray-paired-file-pattern {
            my @paired-filenames = sorted-filenames-matching($sarray-paired-file-pattern);

            if @paired-filenames.elems != @filenames.elems {
                note "Number of paired filenames is not equal to number of regular filenames";
                my $max-index = max @filenames.end, @paired-filenames.end;

                note "File name (paired file name):";
                for 0 .. $max-index -> $index {
                    my $first-filename  =        @filenames[$index] // '';
                    my $paired-filename = @paired-filenames[$index] // '';
                    note "$first-filename ($paired-filename)";
                }

                note "Exiting ...";
                exit;
            }

            #WARNING: Below is actually body, not header
            $header ~= 'PAIRED_FILES=('
                     ~ @paired-filenames.join(' ')
                     ~ ')'
                     ~ "\n\n";
            $header ~= 'PAIRED_FILE=${PAIRED_FILES[$SLURM_ARRAY_TASK_ID]}' ~ "\n";

            my @filename-prefixes;

            for (@filenames Z @paired-filenames).flat -> $file, $paired-file {
                my $prefix = common-prefix-for($file, $paired-file);
                @filename-prefixes.append($prefix);
            }

            #WARNING: Below is actually body, not header
            $header ~= 'FILENAME_PREFIXES=('
                     ~ @filename-prefixes.join(' ')
                     ~ ')'
                     ~ "\n\n";
            $header ~= 'FILENAME_PREFIX=${FILENAME_PREFIXES[$SLURM_ARRAY_TASK_ID]}' ~ "\n";
        }
    }

    #WARNING: Below is actually body, not header
    $header ~=  qq:heredoc/END/;

        # list all loaded modules
        module list
        END

    return $header;
}

sub sorted-filenames-matching ($pattern) {
    return dir(test => / (<$pattern>) / ).sort;
}

sub replace_nonword_characters ( $name is copy)  # copies can be modified within a subroutine
{
    $name ~~ s:g/\W/_/; # Search globally and replace nonword characters with underscore
    return $name;
}

# Create script name based on the job name
# If needed, make the scriptname versioned to avoid overwriting previous batch files
sub job_script_name_for ( $job )
{
    my $job_name    = replace_nonword_characters($job);
    my $version     = 0;
    my $script_name = "$job_name.sbatch";

    # Increment the version number until a unique script name is created
    while ( $script_name.IO ~~ :e)
    {
        $version++;
        $script_name        = "$job_name.sbatch.$version";
    }

    return $script_name;
}

sub common-prefix-for ($a, $b) {
    my $current-substring = $a.substr(0,1);
    my $longest-substring;

    while $b.starts-with($current-substring) {
        $longest-substring = $current-substring;
        $current-substring = $a.substr(0,$++);
    }

    return $longest-substring;
}