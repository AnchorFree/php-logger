package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"math"
	"os"
	"regexp"
	"syscall"
	"time"
)

var (
	confFilePath = flag.String("config", "config.yaml", "Config file path.")
)

var (
	conf = getConfig()
)

func init() {
	flag.Parse()
	createPipes()
}

func main() {

	start := time.Now()

	oscillationPeriod := 10 * time.Minute
	oscillationFactor := func() float64 {
		return 2 + math.Sin(math.Sin(2*math.Pi*float64(time.Since(start))/float64(oscillationPeriod)))
	}

	for _, v := range conf.Inputs {

		go func(v input) {
			pipe, err := os.OpenFile(v.Path, os.O_RDONLY, os.ModeNamedPipe)

			if err != nil {
				log.Panic(err)
			}
			var completeString string
			for {
				reader := bufio.NewReader(pipe)
				scanner := bufio.NewScanner(reader)

				if v.Multiline.Enabled {
					for scanner.Scan() {
						line := scanner.Text()
						if isMultilineStart(&line, &v.Multiline.FirstLine) {
							parseMessage(&completeString, &v)
							completeString = line
						} else {
							completeString += line
						}
					}
				} else {
					for scanner.Scan() {
						line := scanner.Text()
						parseMessage(&line, &v)
					}
				}
				time.Sleep(time.Duration(50*oscillationFactor()) * time.Millisecond)
			}
		}(v)
	}

	for {
		time.Sleep(time.Duration(500*oscillationFactor()) * time.Millisecond)
	}
}

func isMultilineStart(line *string, parser *string) bool {
	newLineStart := regexp.MustCompile(*parser)
	if newLineStart.MatchString(*line) {
		return true
	}
	return false
}

func parseMessage(msg *string, conf *input) {
	result := make(map[string]string)
	if len((*conf).Parsers) > 0 {
		for _, parser := range (*conf).Parsers {
			rExp := regexp.MustCompile(parser)
			match := rExp.FindStringSubmatch(*msg)

			if len(match) == len(rExp.SubexpNames()) && len(match) > 1 {
				for k, v := range rExp.SubexpNames() {
					if k != 0 && v != "" {
						result[v] = match[k]
					}
				}
				wrapJSON(&result, conf)
				break
			}
		}
		if len(result) == 0 {
			if len(*msg) > 0 {
				result["log"] = *msg
				wrapJSON(&result, conf)
			}
		}
	} else {
		if len(*msg) > 0 {
			result["log"] = *msg
			wrapJSON(&result, conf)
		}
	}
}

func wrapJSON(msg *map[string]string, conf *input) {
	if len((*conf).Tags) > 0 {
		addTagsToMsg(msg, conf)
	}
	val, err := json.Marshal(*msg)
	if err != nil {
		log.Println(err)
	}
	fmt.Println(string(val))
}

func addTagsToMsg(msg *map[string]string, conf *input) {
	for _, v := range (*conf).Tags {
		(*msg)[v.Name] = v.Value
	}
}

func createPipes() {
	for _, v := range conf.Inputs {
		if _, err := os.Stat(v.Path); os.IsNotExist(err) {
			err = syscall.Mkfifo(v.Path, 0666)
			if err != nil {
				log.Panic(err)
			}
			log.Printf("Pipe %s has been created", v.Path)
		}
	}
}
