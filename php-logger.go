package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"net"
	"os"
	"regexp"
	"strings"
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
}

func main() {

	start := time.Now()

	oscillationPeriod := 10 * time.Minute
	oscillationFactor := func() float64 {
		return 2 + math.Sin(math.Sin(2*math.Pi*float64(time.Since(start))/float64(oscillationPeriod)))
	}

	for _, v := range conf.Inputs {
		purgeListener(v.Path, v.Type)

		switch v.Type {
		case "pipe":
			go func(v input) {
				err := syscall.Mkfifo(v.Path, 0666)
				if err != nil {
					log.Panicf("Pipe creating error: %s", err)
				}
				log.Printf("Pipe %s has been created", v.Path)
				for {
					pipe, err := os.OpenFile(v.Path, os.O_RDONLY, os.ModeNamedPipe)
					if err != nil {
						log.Panicf("Pipe reading error: %s", err)
					}
					go readerJob(v, pipe, oscillationFactor())
				}
			}(v)
		case "socket":
			go func(v input) {
				listener, err := net.Listen("unix", v.Path)
				if err != nil {
					log.Printf("Listener: Listen Error: %s\n", err)
				}
				log.Printf("Socket %s has been created", v.Path)
				for {
					conn, err := listener.Accept()
					if err != nil {
						log.Printf("Listener: Accept Error: %s\n", err)
						continue
					}
					go readerJob(v, conn, oscillationFactor())
				}
			}(v)
		default:
			log.Printf("Creating resource error. Unrecognized %s resoucre. Only [socket|pipe] allowed", v.Type)
		}
	}
	for {
		time.Sleep(time.Duration(500*oscillationFactor()) * time.Millisecond)
	}
}

func purgeListener(p string, t string) {
	if _, err := os.Stat(p); err == nil {
		err := os.Remove(p)
		if err != nil {
			log.Printf("%s removing error: %s", t, err)
		}
	}
}

func readerJob(v input, f io.Reader, of float64) {
	var completeString string
	multilineTimer := time.Now()
	for {
		reader := bufio.NewReader(f)
		scanner := bufio.NewScanner(reader)

		if v.Multiline.Enabled {
			if time.Since(multilineTimer).Seconds() > v.Multiline.FlushInterval && len(completeString) > 0 {
				parseMessage(&completeString, &v)
				completeString = ""
			}
			for scanner.Scan() {
				line := scanner.Text()
				if isMultilineStart(&line, &v.Multiline.FirstLine) {
					parseMessage(&completeString, &v)
					completeString = line
				} else {
					completeString += " " + line
				}
			}
		} else {
			for scanner.Scan() {
				line := scanner.Text()
				parseMessage(&line, &v)
			}
		}
		time.Sleep(time.Duration(50*of) * time.Millisecond)
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
	*msg = strings.Trim(*msg, " ")
	result := make(map[string]string)
	if len((*conf).Parsers) > 0 {
		for _, parser := range (*conf).Parsers {
			rExp, err := regexp.Compile(parser)

			if err != nil {
				log.Println(err)
				continue
			}

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
				result["message"] = *msg
				wrapJSON(&result, conf)
			}
		}
	} else {
		if len(*msg) > 0 {
			result["message"] = *msg
			wrapJSON(&result, conf)
		}
	}
}

func wrapJSON(msg *map[string]string, conf *input) {
	err := json.Unmarshal(([]byte((*msg)["message"])), msg)

	if err == nil {
		delete((*msg), "message")
	}

	overridePHPError(msg)

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
		if strings.HasPrefix(v.Value, "$") {
			(*msg)[v.Name] = os.Getenv(strings.TrimLeft(v.Value, "$"))
		} else {
			(*msg)[v.Name] = v.Value
		}
	}
}

func overridePHPError(msg *map[string]string) {
	if (*msg)["event_type"] == "php.error" {
		(*msg)["php_error_log"] = fmt.Sprintf("{\"level\":\"%s\", \"error\": \"%s\"}", (*msg)["severity"], (*msg)["msg"])
	}
}
