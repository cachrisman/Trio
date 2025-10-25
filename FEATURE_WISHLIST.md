# Trio Feature Wish List

This document outlines potential future improvements and enhancements for the Trio diabetes management app. Each feature includes implementation details, difficulty assessment, and potential blockers.

## Live Activity Improvements

### 1. Temp Target Display Enhancement
**Description**: Improve live activity to show Temp Targets similar to how Overrides are currently displayed.

**Current State**: Live activity shows overrides with a purple badge in the top-right corner displaying the override name. Temp targets are not currently displayed in live activity.

**Proposed Implementation**:
- Add temp target data to `LiveActivityAttributes` and `ContentAdditionalState`
- Create a temp target badge similar to the override badge but with different styling (e.g., green color scheme)
- Display temp target name, target range, and remaining duration
- Position the badge below or alongside the override badge when both are active

**Difficulty**: Medium
- **Easy**: Data structure already exists for temp targets
- **Medium**: Need to modify live activity data flow and UI layout
- **Challenges**: Space constraints in live activity, ensuring both override and temp target badges fit

**Potential Blockers**:
- Live activity space limitations
- iOS Live Activity size restrictions
- Ensuring readability on different device sizes

### 2. Live Activity Layout Optimization
**Description**: Adjust live activity to make glucose/delta/trend much larger and shrink the graph size horizontally.

**Current State**: Live activity shows a 6-hour glucose chart with relatively small glucose values and trend information.

**Proposed Implementation**:
- Reduce chart width from 6 hours to 3-4 hours
- Increase font sizes for glucose value, delta, and trend arrow
- Make glucose value the primary focal point
- Optimize chart height vs. text size ratio
- Consider removing or minimizing secondary information to focus on core glucose data

**Difficulty**: Medium
- **Easy**: Font size and layout adjustments
- **Medium**: Chart scaling and data range adjustments
- **Challenges**: Maintaining chart readability with reduced width

**Potential Blockers**:
- Live activity size constraints
- Chart readability with compressed time range
- User preference for current layout

## Watch Complications Expansion

### 3. Enhanced Circular Complication with Open Gauge Range
**Description**: Update existing circular complication to include open gauge range visualization.

**Current State**: Circular complication shows glucose value, trend, and delta in a compact format.

**Proposed Implementation**:
- Add gauge-style visualization showing glucose range (low to high)
- Use color coding to indicate current position within range
- Maintain current text information while adding visual context
- Implement smooth gauge animation for glucose changes

**Difficulty**: Medium-High
- **Easy**: Basic gauge implementation
- **Medium**: Color coding and range calculation
- **Hard**: Smooth animations and space optimization
- **Challenges**: Fitting gauge + text in limited circular space

**Potential Blockers**:
- Watch complication size limitations
- Performance impact of animations
- Readability on small screens

### 4. New Circular Complication - Stack Text Style
**Description**: Create a new circular complication using Stack Text layout similar to the corner complication.

**Current State**: Corner complication uses curved text around the watch face edge.

**Proposed Implementation**:
- Vertical stack layout: glucose value (large), trend arrow (medium), delta + time (small)
- Similar to corner complication but in circular format
- Optimize font sizes for circular constraint
- Use color coding for data freshness

**Difficulty**: Low-Medium
- **Easy**: Reuse existing corner complication logic
- **Medium**: Adapt layout for circular format
- **Challenges**: Font size optimization for circular space

**Potential Blockers**:
- Limited circular space
- Font readability at small sizes

### 5. New Circular Complication - Bezel Style
**Description**: Create a circular complication that utilizes the watch bezel area.

**Current State**: No bezel-style complications currently implemented.

**Proposed Implementation**:
- Use outer ring of circular space for glucose range visualization
- Inner area for glucose value and trend
- Rotating indicator showing current glucose position
- Color-coded segments for different glucose ranges

**Difficulty**: High
- **Hard**: Custom bezel drawing and rotation calculations
- **Challenges**: Complex geometry and animation
- **Technical**: Requires custom drawing and gesture handling

**Potential Blockers**:
- Complex implementation
- WatchOS bezel interaction limitations
- Performance considerations

### 6. New Circular Complication - X-Large Watch Face
**Description**: Create a circular complication optimized for X-Large watch faces.

**Current State**: Current complications are designed for standard watch face sizes.

**Proposed Implementation**:
- Larger font sizes and more detailed information
- Multi-line layout with glucose, trend, delta, and time
- Enhanced visual elements (icons, better spacing)
- More comprehensive data display

**Difficulty**: Low-Medium
- **Easy**: Scale up existing designs
- **Medium**: Optimize layout for larger space
- **Challenges**: Ensuring consistency across watch face sizes

**Potential Blockers**:
- Limited to X-Large watch faces only
- User adoption of X-Large faces

### 7. New Rectangular Large Image Complication
**Description**: Create a rectangular large image complication showing current glucose, delta, recency text, and a graph of recent glucose.

**Current State**: No rectangular complications currently implemented.

**Proposed Implementation**:
- Wide rectangular format with glucose chart
- Large glucose value with trend arrow
- Delta and recency information
- Mini glucose chart (last 2-3 hours)
- Color-coded glucose range background

**Difficulty**: Medium-High
- **Medium**: Chart implementation in complication
- **Hard**: Image generation and caching
- **Challenges**: Performance optimization for frequent updates

**Potential Blockers**:
- WatchOS complication image generation limitations
- Performance impact of chart rendering
- Update frequency restrictions

## Additional Watch Complication Suggestions

### 8. Modular Complication
**Description**: Create a modular complication that can be customized by users to show different combinations of data.

**Implementation**:
- User-configurable data display options
- Multiple layout templates
- Settings sync from iPhone app
- Quick toggle between different data sets

**Difficulty**: High
- **Hard**: User configuration system
- **Challenges**: Settings synchronization and UI complexity

### 9. Trend-Focused Complication
**Description**: Create a complication that emphasizes glucose trend over absolute values.

**Implementation**:
- Large trend arrow as primary element
- Smaller glucose value
- Trend direction indicators
- Color-coded trend strength

**Difficulty**: Low-Medium
- **Easy**: Focus on existing trend data
- **Medium**: Visual design optimization

### 10. IOB/COB Focused Complication
**Description**: Create a complication that shows insulin on board (IOB) and carbs on board (COB).

**Implementation**:
- IOB and COB values with progress indicators
- Time remaining for each
- Color coding for safety ranges
- Quick access to treatment history

**Difficulty**: Medium
- **Medium**: Progress indicator implementation
- **Challenges**: Data accuracy and update frequency

## Live Activity Platform Expansion

### 11. iPhone Widgets on Mac Support
**Description**: Add support for live activity using iPhoneWidgetsOnMac framework.

**Current State**: Live activity is currently iOS-only.

**Proposed Implementation**:
- Implement iPhoneWidgetsOnMac framework
- Adapt live activity layout for Mac display
- Ensure proper data synchronization
- Optimize for larger Mac screen real estate

**Difficulty**: Medium
- **Easy**: Framework integration
- **Medium**: Layout adaptation for Mac
- **Challenges**: Different interaction patterns and screen sizes

**Potential Blockers**:
- iPhoneWidgetsOnMac framework limitations
- Mac-specific UI/UX considerations
- User adoption on Mac platform

## Watch App User Experience Improvements

### 12. Intuitive Carb Input/Bolus Flow Redesign
**Description**: Adjust the watch app carb input/bolus flow to make it more intuitive.

**Current State**: Users have three separate options: input carbs only, make bolus only, or input carbs and make bolus. The flow can be confusing.

**Proposed Implementation**:
- **Unified Entry Point**: Single "Add Treatment" button that intelligently guides users
- **Smart Flow**: 
  - If glucose is high → suggest bolus first, then ask about carbs
  - If glucose is normal → suggest meal bolus combo
  - If glucose is low → suggest carbs only
- **Contextual Suggestions**: Show recommended actions based on current glucose and trend
- **Simplified Navigation**: Reduce the number of decision points
- **Quick Actions**: Add shortcuts for common scenarios (meal bolus, correction bolus, snack)

**Flow Redesign**:
1. **Single Entry Point**: "Add Treatment" button
2. **Smart Detection**: App suggests the most likely action based on context
3. **Quick Override**: Users can easily switch to different treatment type
4. **Progressive Disclosure**: Show additional options only when needed
5. **Confirmation Flow**: Streamlined confirmation with clear next steps

**Difficulty**: Medium-High
- **Easy**: UI flow changes
- **Medium**: Smart suggestion logic implementation
- **Hard**: Context-aware decision making
- **Challenges**: Balancing simplicity with functionality

**Potential Blockers**:
- Complex decision logic implementation
- User testing and feedback integration
- Maintaining backward compatibility

## Additional Feature Suggestions

### 13. Voice-Controlled Treatments
**Description**: Add voice control for common treatment actions on Apple Watch.

**Implementation**:
- "Hey Siri, log 30 grams of carbs"
- "Hey Siri, give me 2 units of insulin"
- Voice confirmation for safety
- Integration with existing treatment flow

**Difficulty**: Medium
- **Medium**: Siri integration and voice recognition
- **Challenges**: Safety confirmations and error handling

### 14. Haptic Feedback Enhancements
**Description**: Improve haptic feedback for treatment confirmations and alerts.

**Implementation**:
- Different haptic patterns for different actions
- Success/failure haptic feedback
- Glucose trend haptic indicators
- Customizable haptic patterns

**Difficulty**: Low-Medium
- **Easy**: Basic haptic implementation
- **Medium**: Pattern customization and user preferences

### 15. Quick Action Complications
**Description**: Create complications that allow quick treatment actions without opening the app.

**Implementation**:
- Force touch on complication for quick actions
- Pre-defined treatment amounts
- Safety confirmations
- Integration with existing treatment system

**Difficulty**: High
- **Hard**: Force touch interaction handling
- **Challenges**: Safety considerations and user interface design

### 16. Predictive Complications
**Description**: Show predicted glucose values and trends in complications.

**Implementation**:
- Display predicted glucose in 15-30 minutes
- Trend prediction indicators
- Confidence levels for predictions
- Integration with existing prediction algorithms

**Difficulty**: High
- **Hard**: Prediction algorithm integration
- **Challenges**: Accuracy and reliability of predictions

## Implementation Priority Recommendations

### High Priority (Quick Wins)
1. Live Activity Layout Optimization (#2)
2. New Circular Complication - Stack Text Style (#4)
3. New Circular Complication - X-Large Watch Face (#6)

### Medium Priority (Significant Impact)
1. Temp Target Display Enhancement (#1)
2. Enhanced Circular Complication with Open Gauge Range (#3)
3. Intuitive Carb Input/Bolus Flow Redesign (#12)
4. iPhone Widgets on Mac Support (#11)

### Low Priority (Nice to Have)
1. New Circular Complication - Bezel Style (#5)
2. New Rectangular Large Image Complication (#7)
3. Voice-Controlled Treatments (#13)
4. Haptic Feedback Enhancements (#14)

### Future Considerations
1. Modular Complication (#8)
2. Quick Action Complications (#15)
3. Predictive Complications (#16)

## Technical Considerations

### Data Synchronization
- All new complications will need to integrate with existing `TrioComplicationDataStore`
- Ensure efficient data transfer between iPhone and Watch
- Consider battery impact of increased complication updates

### Performance
- Complication updates should be optimized for battery life
- Chart rendering in complications needs to be efficient
- Consider caching strategies for complex visualizations

### User Experience
- Maintain consistency across all complication types
- Ensure accessibility compliance
- Provide clear visual hierarchy and readability

### Testing Strategy
- Comprehensive testing across different watch sizes
- User testing for flow improvements
- Performance testing for battery impact
- Accessibility testing for all new features

---

*This document should be reviewed and updated regularly as new iOS/watchOS features become available and user feedback is collected.*
