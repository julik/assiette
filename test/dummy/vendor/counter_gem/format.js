import {evaluations} from "./counter.js"

export function format() {
  return "evaluated " + evaluations() + " time(s)"
}
